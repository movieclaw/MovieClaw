package api

import (
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/movieclaw/movieclaw/cli/internal/clierr"
)

// unauthorized 起一个只会回 401 的服务端，用来观察 CLI 侧的错误映射。
func unauthorized(t *testing.T, body string) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return server.URL
}

func requestErr(t *testing.T, server string) *clierr.Error {
	t.Helper()
	client, err := New(server, 5*time.Second, false)
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	_, err = client.Request(http.MethodGet, "/auth/me", nil, nil)
	var cliErr *clierr.Error
	if err == nil || !asCliErr(err, &cliErr) {
		t.Fatalf("应当是 CLI 错误：%v", err)
	}
	return cliErr
}

func asCliErr(err error, target **clierr.Error) bool {
	if e, ok := err.(*clierr.Error); ok {
		*target = e
		return true
	}
	return false
}

// TestUnauthorizedHintFollowsCredentialSource 校验 401 的提示按凭证来源分流。
//
// 凭证来自环境变量时「请先执行 mclaw login」是错的下一步：配对写进凭证文件的
// 令牌会继续被环境变量遮住，用户照做只是白跑一趟，而真正的原因（令牌写错了、
// 或者已经在网页里被吊销）一直没被指出来。
func TestUnauthorizedHintFollowsCredentialSource(t *testing.T) {
	server := unauthorized(t, `{"success":false,"code":"UNAUTHORIZED","message":"令牌无效或已吊销"}`)

	t.Run("凭证来自环境变量", func(t *testing.T) {
		t.Setenv("MOVIECLAW_TOKEN", "mclaw_被吊销的令牌")
		cliErr := requestErr(t, server)
		if cliErr.ExitCode != clierr.Auth {
			t.Errorf("退出码应当是认证失败：%d", cliErr.ExitCode)
		}
		if !strings.Contains(cliErr.Hint, "MOVIECLAW_TOKEN") {
			t.Errorf("没点名当前凭证来自哪个环境变量：%q", cliErr.Hint)
		}
		if !strings.Contains(cliErr.Hint, "吊销") {
			t.Errorf("没提示去看是不是被吊销了：%q", cliErr.Hint)
		}
		if strings.Contains(cliErr.Hint, "mclaw login") {
			t.Errorf("环境变量在场时不该建议去配对——配对结果会被它遮蔽：%q", cliErr.Hint)
		}
	})

	t.Run("凭证来自本地文件", func(t *testing.T) {
		t.Setenv("MOVIECLAW_TOKEN", "")
		t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
		cliErr := requestErr(t, server)
		if !strings.Contains(cliErr.Hint, "mclaw login") {
			t.Errorf("没有环境变量时应当指向配对：%q", cliErr.Hint)
		}
	})
}

// TestUnauthorizedPassesServerMessageThrough 校验服务端说了具体原因就用它的话，
// 别用「未登录或会话已过期」把「令牌已吊销」这种确切结论盖掉。
func TestUnauthorizedPassesServerMessageThrough(t *testing.T) {
	t.Setenv("MOVIECLAW_TOKEN", "mclaw_x")
	server := unauthorized(t, `{"success":false,"code":"UNAUTHORIZED","message":"令牌无效或已吊销"}`)
	if got := requestErr(t, server).Message; got != "令牌无效或已吊销" {
		t.Errorf("服务端的具体原因被盖掉了：%q", got)
	}
}

// recorder 起一个总是成功的服务端，记下最近一次请求的请求头。
func recorder(t *testing.T) (string, *http.Header) {
	t.Helper()
	var seen http.Header
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Clone()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"success":true,"code":"OK","message":"","data":{}}`))
	}))
	t.Cleanup(server.Close)
	return server.URL, &seen
}

// TestRequestsCarryUserAgent 校验每个请求都报上 mclaw 自己的名字、版本与平台。
//
// 服务端把登录设备最近一次请求的 User-Agent 记在设备行上；不设的话记下来的是
// Go 标准库的 Go-http-client/1.1，设备列表里看不出这是哪个客户端、哪个版本。
func TestRequestsCarryUserAgent(t *testing.T) {
	server, seen := recorder(t)
	t.Setenv("MOVIECLAW_TOKEN", "mclaw_x")
	previous := Version
	Version = "9.9.9"
	t.Cleanup(func() { Version = previous })

	client, err := New(server, 5*time.Second, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Request(http.MethodGet, "/auth/me", nil, nil); err != nil {
		t.Fatal(err)
	}
	want := "mclaw/9.9.9 (" + runtime.GOOS + "/" + runtime.GOARCH + ")"
	if got := seen.Get("User-Agent"); got != want {
		t.Errorf("User-Agent = %q，期望 %q", got, want)
	}
}

// TestNewWithTokenIgnoresEnvironment 校验指定令牌的客户端不被环境变量遮蔽。
//
// mclaw logout 靠它注销凭证文件里的那一枚：环境变量里的令牌可能属于 Agent 或
// CI，要是被 logout 顺手注销，别处会莫名其妙掉线。
func TestNewWithTokenIgnoresEnvironment(t *testing.T) {
	server, seen := recorder(t)
	t.Setenv("MOVIECLAW_TOKEN", "mclaw_env")

	client, err := NewWithToken(server, "mclaw_local", 5*time.Second, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Request(http.MethodDelete, "/auth/devices/current", nil, nil); err != nil {
		t.Fatal(err)
	}
	if got := seen.Get("Authorization"); got != "Bearer mclaw_local" {
		t.Errorf("带错了令牌：%q", got)
	}
}

// TestTokenForPrefersEnv 校验环境变量优先于落盘凭证——这是 Agent 工作区与
// 无人值守环境的主通道，且此时完全不读凭证文件（只读文件系统里也能跑）。
func TestTokenForPrefersEnv(t *testing.T) {
	t.Setenv("MOVIECLAW_TOKEN", "mclaw_来自环境变量")
	// 指向一个不存在的目录：真去读凭证文件的话这里会暴露出来
	t.Setenv("MOVIECLAW_CONFIG_DIR", "/nonexistent/movieclaw-config")

	token, err := TokenFor("http://192.168.1.10:3000")
	if err != nil {
		t.Fatalf("环境变量在场时不该去碰凭证文件：%v", err)
	}
	if token != "mclaw_来自环境变量" {
		t.Errorf("没用环境变量里的令牌：%q", token)
	}
}

// 插件接口用 FastAPI 的 HTTPException 报错（{"detail": "原因"}），原因要直接当错误信息给出。
func TestPlainDetailErrorBecomesTheMessage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"detail": "找不到城市：火星"}`))
	}))
	t.Cleanup(server.Close)
	cliErr := requestErr(t, server.URL)
	if cliErr.Message != "找不到城市：火星" || cliErr.Details != nil {
		t.Fatalf("错误信息应是 detail 原文：%q %v", cliErr.Message, cliErr.Details)
	}
}
