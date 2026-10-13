package overlay

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"runtime"
	"time"

	"github.com/movieclaw/movieclaw/cli/internal/clierr"
	"github.com/spf13/cobra"
)

type chatGPTCallback struct {
	Code, State, ClientID string
	Err                   error
}

// NewLLMGroup 保留生成层的 llm 命令，只添加需要本地 loopback 的登录编排。
func NewLLMGroup() *cobra.Command {
	group := &cobra.Command{Use: "llm", Short: "模型接入与设定"}
	chatgpt := &cobra.Command{Use: "chatgpt", Short: "连接 ChatGPT 订阅"}
	var name, appName string
	var providerID int
	var noOpen bool
	login := &cobra.Command{
		Use: "login", Short: "在本机浏览器授权，将订阅连接到服务器",
		Long: "先用 mclaw login 配对服务器，再在运行浏览器的电脑执行此命令。\n令牌由服务器加密保存，不显示或写入电脑；连接后手机和网页均可使用。\n重新授权已有接入时使用 --provider ID；新增账号则省略该参数。",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if !stdinIsTTY() {
				return clierr.Usagef("请在电脑的交互终端运行此命令，并在官方浏览器页面授权")
			}
			return runChatGPTLogin(cmd, name, appName, providerID, noOpen)
		},
	}
	login.Flags().StringVar(&name, "name", "ChatGPT", "新增模型接入的名称")
	login.Flags().StringVar(&appName, "app-name", "MovieClaw", "授权页面显示的实际应用名称")
	login.Flags().IntVar(&providerID, "provider", 0, "重新授权已有 ChatGPT 接入的 ID")
	login.Flags().BoolVar(&noOpen, "no-open", false, "只显示登录地址，由用户在本机浏览器打开")
	chatgpt.AddCommand(login)
	group.AddCommand(chatgpt)
	return group
}

func openChatGPTBrowser(address string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", address).Run()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", address).Run()
	default:
		return exec.Command("xdg-open", address).Run()
	}
}

func runChatGPTLogin(cmd *cobra.Command, name, appName string, providerID int, noOpen bool) error {
	s := SettingsOf(cmd)
	// 不允许 debug 请求体日志泄漏授权码；整个登录流程使用独立的非 debug 客户端。
	settings := *s
	settings.Debug = false
	if settings.Timeout < 2*time.Minute {
		settings.Timeout = 2 * time.Minute
	}
	client, err := settings.NewAPI()
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return clierr.New("无法启动本机授权回调")
	}
	defer listener.Close()
	redirectURI := "http://" + listener.Addr().String() + "/auth/callback"
	body := map[string]any{"redirect_uri": redirectURI, "name": name, "app_name": appName}
	if providerID != 0 {
		body["provider_id"] = providerID
	}
	result, err := client.Request(http.MethodPost, "/llm/chatgpt/authorize", nil, body)
	if err != nil {
		return err
	}
	attempt := stringField(result, "attempt_id", "")
	state := stringField(result, "state", "")
	address := stringField(result, "authorize_url", "")
	parsed, err := url.Parse(address)
	if err != nil || parsed.Scheme != "https" || parsed.Host != "auth.openai.com" || parsed.Path != "/api/accounts/authorize" || attempt == "" || state == "" {
		return clierr.New("服务器返回了无效的 ChatGPT 授权地址")
	}
	callbacks := make(chan chatGPTCallback, 1)
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second, Handler: chatGPTCallbackHandler(listener.Addr().String(), state, callbacks)}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	if noOpen || openChatGPTBrowser(address) != nil {
		fmt.Fprintln(cmd.ErrOrStderr(), "请在这台电脑的浏览器打开：\n"+address)
	} else {
		fmt.Fprintln(cmd.ErrOrStderr(), "请在官方 ChatGPT 页面登录并允许使用订阅。")
	}
	ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Minute)
	defer cancel()
	select {
	case <-ctx.Done():
		return clierr.New("ChatGPT 授权已取消或超时，请重试")
	case callback := <-callbacks:
		if callback.Err != nil {
			return callback.Err
		}
		_, err := client.Request(http.MethodPost, "/llm/chatgpt/complete", nil, map[string]any{
			"attempt_id": attempt, "state": callback.State, "code": callback.Code,
			"client_id": callback.ClientID,
		})
		if err != nil {
			return err
		}
		fmt.Fprintln(cmd.OutOrStdout(), "ChatGPT 订阅已连接。请回到 App 或网页选择模型；额度与现有订阅共享。")
		return nil
	}
}

func chatGPTCallbackHandler(host, state string, callbacks chan<- chatGPTCallback) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		if r.Method != http.MethodGet || r.URL.Path != "/auth/callback" || r.Host != host {
			http.Error(w, "Invalid callback", http.StatusBadRequest)
			return
		}
		query := r.URL.Query()
		if len(query["state"]) != 1 || query.Get("state") != state {
			http.Error(w, "Invalid state", http.StatusBadRequest)
			return
		}
		callback := chatGPTCallback{State: state, Code: query.Get("code"), ClientID: query.Get("client_id")}
		if query.Get("error") != "" {
			callback.Err = errors.New("ChatGPT 授权被取消，请重新连接并允许使用订阅")
		} else if len(query["code"]) != 1 || callback.Code == "" || len(query["client_id"]) > 1 {
			http.Error(w, "Missing authorization code", http.StatusBadRequest)
			return
		}
		select {
		case callbacks <- callback:
			fmt.Fprintln(w, "回调已收到，请返回终端查看连接结果。此页面不显示令牌。")
		default:
			http.Error(w, "Callback already received", http.StatusConflict)
		}
	})
}
