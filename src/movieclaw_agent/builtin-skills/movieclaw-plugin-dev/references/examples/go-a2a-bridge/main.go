// A2A 桥：用 Go 写的 MovieClaw 插件（docs/design/plugin-ipc-http.md §9、plugin-agent.md）。
//
// 把 A2A（Agent-to-Agent）协议的 JSON-RPC 请求转成 MovieClaw AI 助手的一轮对话：
//
//	POST /api/v1/plugins/<id>/a2a   message/send（同步）、message/stream（SSE）
//	GET  /api/v1/plugins/<id>/card  Agent Card
//
// contextId 就是 MovieClaw 的会话编号：带上它就续写同一个会话。
//
// 与宿主的约定（协议见 plugin-ipc-http.md）：
//   - --describe：输出声明（标题、要用的服务、权限）后退出；--validate：校验配置后退出；
//   - 运行时 stdin 第一行是引导信息（网关地址、令牌、条目 id），之后 stdin 关闭；
//   - 插件调宿主：HTTP over Unix 套接字连网关，POST /api/v1/plugin-runtime/{服务}/{方法}；
//   - 宿主调插件：在 --listen-fd 交来的套接字上起 HTTP 服务（这里只有路由）；
//   - 跑起来后调 session.ready 报就绪（一次带上全部声明）；收到 SIGTERM 收尾退出。
//
// 只用标准库。
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const (
	title       = "A2A 桥（Go）"
	permission  = "agent:mclaw"
	callHeader  = "X-MovieClaw-Call"
	runtimePath = "/api/v1/plugin-runtime/"
)

func main() {
	describe := flag.Bool("describe", false, "输出插件声明后退出")
	validate := flag.Bool("validate", false, "校验标准输入里的配置后退出")
	flag.Int("fd-socket", -1, "宿主递文件描述符用的套接字（本插件不用）")
	listenFD := flag.Int("listen-fd", -1, "宿主绑定好的监听套接字")
	flag.Parse()
	log.SetFlags(0)
	log.SetOutput(os.Stderr)

	switch {
	case *describe:
		writeJSON(os.Stdout, map[string]any{
			"type":        "describe",
			"title":       title,
			"inject":      []string{"agent", "plugin-routes"},
			"permissions": []string{permission},
			"config":      nil,
		})
	case *validate:
		_, _ = io.ReadAll(os.Stdin) // 没有配置项：什么都合规
		writeJSON(os.Stdout, map[string]any{"type": "validate", "errors": []any{}})
	default:
		if err := run(*listenFD); err != nil {
			log.Printf("A2A 桥退出：%v", err)
			os.Exit(1)
		}
	}
}

func writeJSON(w io.Writer, v any) {
	data, _ := json.Marshal(v)
	_, _ = w.Write(append(data, '\n'))
}

// ---------------------------------------------------------------------- 宿主网关

type bootstrap struct {
	EntryID string `json:"entry_id"`
	Gateway string `json:"gateway"`
	Token   string `json:"token"`
}

// host 是宿主网关的客户端。callID 是宿主调进来时带的调用号：原样带回，宿主据此恢复上下文
// （入口区、因果链），护栏才对得上。
type host struct {
	client *http.Client
	token  string
}

type hostError struct {
	Status  int
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *hostError) Error() string {
	return fmt.Sprintf("%s（%d）：%s", e.Code, e.Status, e.Message)
}

func newHost(boot bootstrap) *host {
	dial := func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", boot.Gateway)
	}
	return &host{client: &http.Client{Transport: &http.Transport{DialContext: dial}}, token: boot.Token}
}

func (h *host) post(ctx context.Context, callID, service, method string, args any) (*http.Response, error) {
	body, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	url := "http://movieclaw" + runtimePath + service + "/" + method
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+h.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-MovieClaw-Client", "plugin")
	if callID != "" {
		req.Header.Set(callHeader, callID)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		defer resp.Body.Close()
		failure := &hostError{Status: resp.StatusCode}
		_ = json.NewDecoder(resp.Body).Decode(failure)
		return nil, failure
	}
	return resp, nil
}

// call 调一个普通方法，结果解码进 out（可以是 nil）。
func (h *host) call(ctx context.Context, callID, service, method string, args, out any) error {
	resp, err := h.post(ctx, callID, service, method, args)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// stream 调一个流式方法：响应是 ndjson，一行 {"v": 元素} 或以 {"error": …} 结束。
func (h *host) stream(ctx context.Context, callID, service, method string, args any, each func(json.RawMessage) error) error {
	resp, err := h.post(ctx, callID, service, method, args)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		var line struct {
			V     json.RawMessage `json:"v"`
			Error *hostError      `json:"error"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &line); err != nil {
			return err
		}
		if line.Error != nil {
			return line.Error
		}
		if err := each(line.V); err != nil {
			return err
		}
	}
	return scanner.Err()
}

// ---------------------------------------------------------------------- Agent 契约（movieclaw_sdk/agent.py）

type turnRef struct {
	SessionID string `json:"session_id"`
	MessageID string `json:"message_id"`
}

type agentReply struct {
	SessionID string `json:"session_id"`
	MessageID string `json:"message_id"`
	Status    string `json:"status"`
	Text      string `json:"text"`
	Error     string `json:"error"`
}

type turnEvent struct {
	Seq   int         `json:"seq"`
	Type  string      `json:"type"`
	Delta string      `json:"delta"`
	Reply *agentReply `json:"reply"`
	Tool  *struct {
		Phase string `json:"phase"`
		Name  string `json:"name"`
	} `json:"tool"`
}

// ---------------------------------------------------------------------- A2A

type a2aRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  struct {
		Message struct {
			Parts []struct {
				Kind string `json:"kind"`
				Text string `json:"text"`
			} `json:"parts"`
			ContextID string `json:"contextId"`
		} `json:"message"`
	} `json:"params"`
}

type bridge struct {
	host    *host
	entryID string
}

func (b *bridge) prefix() string { return "/api/v1/plugins/" + b.entryID }

func rpcResult(id json.RawMessage, result any) map[string]any {
	return map[string]any{"jsonrpc": "2.0", "id": id, "result": result}
}

func rpcError(id json.RawMessage, code int, message string) map[string]any {
	return map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}}
}

func (b *bridge) handleA2A(w http.ResponseWriter, r *http.Request) {
	var req a2aRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, rpcError(nil, -32700, "请求不是合法的 JSON"))
		return
	}
	var text strings.Builder
	for _, part := range req.Params.Message.Parts {
		if part.Kind == "text" {
			text.WriteString(part.Text)
		}
	}
	callID := r.Header.Get(callHeader)
	start := map[string]any{"content": text.String()}
	if req.Params.Message.ContextID != "" {
		start["session_id"] = req.Params.Message.ContextID
	}
	switch req.Method {
	case "message/send":
		b.send(w, r.Context(), callID, req.ID, start)
	case "message/stream":
		b.streamTurn(w, r.Context(), callID, req.ID, start)
	default:
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, rpcError(req.ID, -32601, "不支持的方法："+req.Method))
	}
}

func (b *bridge) send(w http.ResponseWriter, ctx context.Context, callID string, id json.RawMessage, start map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	var ref turnRef
	if err := b.host.call(ctx, callID, "agent", "start", start, &ref); err != nil {
		writeJSON(w, rpcError(id, -32000, err.Error()))
		return
	}
	var reply agentReply
	args := map[string]any{"session_id": ref.SessionID, "message_id": ref.MessageID, "timeout": 120}
	if err := b.host.call(ctx, callID, "agent", "result", args, &reply); err != nil {
		writeJSON(w, rpcError(id, -32000, err.Error()))
		return
	}
	if reply.Status != "done" {
		writeJSON(w, rpcError(id, -32603, fmt.Sprintf("这一轮没有完成（%s）：%s", reply.Status, reply.Error)))
		return
	}
	writeJSON(w, rpcResult(id, map[string]any{
		"kind":      "message",
		"role":      "agent",
		"messageId": ref.MessageID + "-reply",
		"contextId": ref.SessionID,
		"parts":     []any{map[string]any{"kind": "text", "text": reply.Text}},
	}))
}

func (b *bridge) streamTurn(w http.ResponseWriter, ctx context.Context, callID string, id json.RawMessage, start map[string]any) {
	var ref turnRef
	if err := b.host.call(ctx, callID, "agent", "start", start, &ref); err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, rpcError(id, -32000, err.Error()))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	flusher, _ := w.(http.Flusher)
	emit := func(result any) {
		data, _ := json.Marshal(rpcResult(id, result))
		fmt.Fprintf(w, "data: %s\n\n", data)
		if flusher != nil {
			flusher.Flush()
		}
	}
	status := func(state string, final bool) map[string]any {
		return map[string]any{
			"kind":      "status-update",
			"taskId":    ref.MessageID,
			"contextId": ref.SessionID,
			"status":    map[string]any{"state": state},
			"final":     final,
		}
	}
	emit(status("working", false))
	args := map[string]any{"session_id": ref.SessionID, "message_id": ref.MessageID}
	err := b.host.stream(ctx, callID, "agent", "events", args, func(raw json.RawMessage) error {
		var event turnEvent
		if err := json.Unmarshal(raw, &event); err != nil {
			return err
		}
		switch event.Type {
		case "text":
			emit(map[string]any{
				"kind":      "artifact-update",
				"taskId":    ref.MessageID,
				"contextId": ref.SessionID,
				"append":    true,
				"artifact": map[string]any{
					"artifactId": "reply",
					"parts":      []any{map[string]any{"kind": "text", "text": event.Delta}},
				},
			})
		case "done":
			emit(status("completed", true))
		case "error":
			emit(status("failed", true))
		case "cancelled":
			emit(status("canceled", true))
		}
		return nil
	})
	if err != nil && !errors.Is(err, context.Canceled) {
		// 对端断开（ctx 取消）不算错；其余按失败收尾。运行本身不取消：对端可以凭 contextId 再来
		emit(status("failed", true))
		log.Printf("转发事件出错：%v", err)
	}
}

func (b *bridge) handleCard(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	writeJSON(w, map[string]any{
		"name":               "MovieClaw",
		"description":        "MovieClaw 的 AI 助手：找片、订阅、管理媒体库与下载",
		"url":                b.prefix() + "/a2a",
		"version":            "1.0.0",
		"capabilities":       map[string]any{"streaming": true},
		"defaultInputModes":  []string{"text/plain"},
		"defaultOutputModes": []string{"text/plain"},
		"skills": []any{map[string]any{
			"id":          "movieclaw",
			"name":        "影音管家",
			"description": "查询与操作 MovieClaw（订阅、媒体库、下载、搜索）",
		}},
	})
}

// ---------------------------------------------------------------------- 运行

func run(listenFD int) error {
	line, err := bufio.NewReader(os.Stdin).ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("读不到引导信息：%w", err)
	}
	var boot bootstrap
	if err := json.Unmarshal(line, &boot); err != nil {
		return fmt.Errorf("引导信息不是 JSON：%w", err)
	}
	if listenFD < 0 {
		return errors.New("宿主没有交来监听套接字（--listen-fd）")
	}
	listener, err := net.FileListener(os.NewFile(uintptr(listenFD), "listen"))
	if err != nil {
		return fmt.Errorf("监听套接字不可用：%w", err)
	}
	b := &bridge{host: newHost(boot), entryID: boot.EntryID}
	mux := http.NewServeMux()
	mux.HandleFunc("POST "+b.prefix()+"/a2a", b.handleA2A)
	mux.HandleFunc("GET "+b.prefix()+"/card", b.handleCard)
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("HTTP 服务出错：%v", err)
		}
	}()

	route := func(path, method, name, summary string) map[string]any {
		return map[string]any{
			"path":         path,
			"methods":      []string{method},
			"operation_id": "plugins." + boot.EntryID + "." + name,
			"summary":      summary,
			"name":         name,
			"openapi":      map[string]any{},
		}
	}
	ready := map[string]any{
		"title":         title,
		"listeners":     []any{},
		"contributions": []any{},
		"routes": []any{map[string]any{"zone": "admin", "routes": []any{
			route("/a2a", "POST", "a2a", "A2A JSON-RPC：message/send、message/stream"),
			route("/card", "GET", "card", "A2A Agent Card"),
		}}},
		"callbacks": []any{},
		"serving":   true,
	}
	ctx := context.Background()
	if err := b.host.call(ctx, "", "session", "ready", ready, nil); err != nil {
		return fmt.Errorf("报就绪失败：%w", err)
	}
	log.Printf("%s 已就绪（%s）", title, boot.EntryID)

	// 宿主发 SIGTERM 请插件收尾；宿主没了（父进程变了）也收工
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	parent := os.Getppid()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for running := true; running; {
		select {
		case <-stop:
			running = false
		case <-ticker.C:
			running = os.Getppid() == parent
		}
	}
	shutdown, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return server.Shutdown(shutdown)
}
