package overlay

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/movieclaw/movieclaw/cli/internal/api"
	"github.com/movieclaw/movieclaw/cli/internal/clierr"
	"github.com/movieclaw/movieclaw/cli/internal/config"
	"github.com/movieclaw/movieclaw/cli/internal/discover"
	"github.com/movieclaw/movieclaw/cli/internal/output"
	"github.com/spf13/cobra"
)

func quiet(t *testing.T) {
	t.Helper()
	previous := output.Stderr
	output.Stderr = discardWriter{}
	t.Cleanup(func() { output.Stderr = previous })
}

type discardWriter struct{}

func (discardWriter) Write(p []byte) (int, error) { return len(p), nil }

// TestProbeRejectsNonMovieclaw 是自动发现里最要紧的一道闸：局域网里的真
// Jellyfin 会应答同一句问询，直接拿它的地址去配对只会得到一串看不懂的 404。
func TestProbeRejectsNonMovieclaw(t *testing.T) {
	jellyfin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok","service":"jellyfin"}`))
	}))
	defer jellyfin.Close()
	if _, ok := probeMovieclaw(jellyfin.URL); ok {
		t.Error("真 Jellyfin 被当成了 movieclaw")
	}

	real := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok","service":"movieclaw"}`))
	}))
	defer real.Close()
	name, ok := probeMovieclaw(real.URL)
	if !ok || name != "movieclaw" {
		t.Errorf("movieclaw 没被认出来：name=%q ok=%v", name, ok)
	}
}

// TestProbeRejectsUnreachable 校验发现到但连不上的地址被丢掉——Docker 桥接
// 部署下服务端自报的可能是容器内网段，拿到手也用不了。
func TestProbeRejectsUnreachable(t *testing.T) {
	if _, ok := probeMovieclaw("http://192.0.2.1:3000"); ok {
		t.Error("连不上的地址不该通过确认")
	}
}

func TestChooseServerSingleAsksForConfirmation(t *testing.T) {
	quiet(t)
	found := []discover.Server{{Address: "http://192.168.1.10:3000", Name: "客厅 NAS"}}

	restore := stubYesNo(true)
	got, err := chooseServer(found)
	restore()
	if err != nil || got != found[0].Address {
		t.Fatalf("同意后应当返回该地址：got=%q err=%v", got, err)
	}

	restore = stubYesNo(false)
	_, err = chooseServer(found)
	restore()
	var cliErr *clierr.Error
	if !asCliError(err, &cliErr) || cliErr.ExitCode != clierr.Usage {
		t.Fatalf("拒绝后应当是用法错误（退出码 2）：%v", err)
	}
	if !strings.Contains(cliErr.Hint, "--server") {
		t.Errorf("取消时要告诉用户怎么指定另一台：%q", cliErr.Hint)
	}
}

func TestChooseServerMultipleAsksForIndex(t *testing.T) {
	quiet(t)
	found := []discover.Server{
		{Address: "http://192.168.1.10:3000", Name: "客厅 NAS"},
		{Address: "http://192.168.1.20:3000", Name: "书房"},
	}
	previous := askIndex
	askIndex = func(string, int) int { return 1 }
	got, err := chooseServer(found)
	askIndex = previous
	if err != nil || got != found[1].Address {
		t.Fatalf("应当返回选中的那台：got=%q err=%v", got, err)
	}

	askIndex = func(string, int) int { return -1 } // 输入不合法或直接回车
	_, err = chooseServer(found)
	askIndex = previous
	if err == nil {
		t.Fatal("没选出来时应当报错而不是随便挑一台")
	}
}

// TestDisplayNameFallsBack 校验服务器没配名字时不显示空白。
func TestDisplayNameFallsBack(t *testing.T) {
	if got := displayName(discover.Server{Address: "http://x"}); got != "movieclaw" {
		t.Errorf("缺省名不对：%q", got)
	}
}

func stubYesNo(answer bool) func() {
	previous := askYesNo
	askYesNo = func(string) bool { return answer }
	return func() { askYesNo = previous }
}

// TestResolveOrDiscoverPrefersExplicitServer 校验显式给了地址就不广播——
// 用户说了算，不该被局域网里另一台机器干扰。
func TestResolveOrDiscoverPrefersExplicitServer(t *testing.T) {
	quiet(t)
	called := false
	previous := discoverServers
	discoverServers = func() discovery { called = true; return discovery{} }
	defer func() { discoverServers = previous }()

	got, err := resolveOrDiscover(&Settings{Server: "http://192.168.9.9:3000"})
	if err != nil || got != "http://192.168.9.9:3000" {
		t.Fatalf("显式地址没被采用：got=%q err=%v", got, err)
	}
	if called {
		t.Error("显式给了 --server 还去广播了")
	}
}

// TestResolveOrDiscoverFallsBackToLAN 校验哪儿都没配时退回自动发现。
func TestResolveOrDiscoverFallsBackToLAN(t *testing.T) {
	quiet(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	t.Setenv("MOVIECLAW_SERVER", "")

	previous := discoverServers
	discoverServers = func() discovery {
		return discovery{Confirmed: []discover.Server{
			{Address: "http://192.168.1.10:3000", Name: "客厅 NAS"},
		}}
	}
	defer func() { discoverServers = previous }()
	restore := stubYesNo(true)
	defer restore()

	got, err := resolveOrDiscover(&Settings{})
	if err != nil || got != "http://192.168.1.10:3000" {
		t.Fatalf("没退回自动发现：got=%q err=%v", got, err)
	}
}

// TestResolveOrDiscoverExplainsBothCauses 校验一台都没找到时，报错要同时说清
// 「怎么手工给地址」和「为什么可能找不到」——只说一半用户就得自己猜。
func TestResolveOrDiscoverExplainsBothCauses(t *testing.T) {
	quiet(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	t.Setenv("MOVIECLAW_SERVER", "")

	previous := discoverServers
	discoverServers = func() discovery { return discovery{} }
	defer func() { discoverServers = previous }()

	_, err := resolveOrDiscover(&Settings{})
	var cliErr *clierr.Error
	if !asCliError(err, &cliErr) {
		t.Fatalf("应当是 CLI 错误：%v", err)
	}
	if !strings.Contains(cliErr.Message, "局域网内也没有找到") {
		t.Errorf("没说明自动查找也失败了：%q", cliErr.Message)
	}
	for _, want := range []string{"--server", "MOVIECLAW_SERVER", "UDP 7359"} {
		if !strings.Contains(cliErr.Hint, want) {
			t.Errorf("提示里缺少 %q：%s", want, cliErr.Hint)
		}
	}
}

// TestResolveOrDiscoverKeepsContextError 校验用户明确指了个不存在的上下文时
// 直接报错，不去猜一台机器给他。
func TestResolveOrDiscoverKeepsContextError(t *testing.T) {
	quiet(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	t.Setenv("MOVIECLAW_SERVER", "")

	called := false
	previous := discoverServers
	discoverServers = func() discovery { called = true; return discovery{} }
	defer func() { discoverServers = previous }()

	_, err := resolveOrDiscover(&Settings{Context: "打错的上下文名"})
	if err == nil || !strings.Contains(err.Error(), "上下文不存在") {
		t.Fatalf("应当透出上下文错误：%v", err)
	}
	if called {
		t.Error("上下文写错时不该退回广播——猜一台给他比报错更糟")
	}
}

// TestUnreachableDiscoveryIsReportedNotSwallowed 校验「应答了但连不上」这一种
// 结果被单独说明：桥接部署下最常见，咽下去只报「没找到」会让用户查错方向。
func TestUnreachableDiscoveryIsReportedNotSwallowed(t *testing.T) {
	quiet(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	t.Setenv("MOVIECLAW_SERVER", "")

	previous := discoverServers
	discoverServers = func() discovery {
		return discovery{Unreachable: []string{"http://172.17.0.2:3000"}}
	}
	defer func() { discoverServers = previous }()

	_, err := resolveOrDiscover(&Settings{})
	var cliErr *clierr.Error
	if !asCliError(err, &cliErr) {
		t.Fatalf("应当是 CLI 错误：%v", err)
	}
	if !strings.Contains(cliErr.Message, "172.17.0.2") {
		t.Errorf("没把连不上的地址报出来：%q", cliErr.Message)
	}
	if !strings.Contains(cliErr.Hint, "对外访问地址") {
		t.Errorf("没指向真正的修法：%q", cliErr.Hint)
	}
}

// ---------------------------------------------------------------------------
// 环境变量授权与配对流的相互作用
// ---------------------------------------------------------------------------

// TestLoginRefusesWhenEnvTokenPresent 校验带着 MOVIECLAW_TOKEN 配对会被拦下。
//
// 这是环境变量授权最隐蔽的一个坑：配对本身会成功，令牌也确实写进了凭证文件，
// 但每次请求都被优先级更高的环境变量遮住——用户看到的是「我明明刚配对成功，
// 身份却还是老的」，且全程没有任何报错。
func TestLoginRefusesWhenEnvTokenPresent(t *testing.T) {
	quiet(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	t.Setenv("MOVIECLAW_TOKEN", "mclaw_环境变量里的令牌")

	called := false
	previous := discoverServers
	discoverServers = func() discovery { called = true; return discovery{} }
	defer func() { discoverServers = previous }()

	err := runLogin(&Settings{Server: "http://192.168.1.10:3000"}, "")
	var cliErr *clierr.Error
	if !asCliError(err, &cliErr) || cliErr.ExitCode != clierr.Usage {
		t.Fatalf("应当以用法错误退出：%v", err)
	}
	if !strings.Contains(cliErr.Message, "MOVIECLAW_TOKEN") {
		t.Errorf("没点名是哪个环境变量在遮蔽：%q", cliErr.Message)
	}
	if !strings.Contains(cliErr.Hint, "unset") {
		t.Errorf("提示里要给出可照做的下一步：%q", cliErr.Hint)
	}
	if called {
		t.Error("拦下之前不该已经去广播了")
	}
}

// TestLoginEnvGuardRunsBeforeTTYCheck 校验 env 令牌的拦截发生在 TTY 判断之前。
//
// 顺序有实际意义：容器和 CI 里两个条件同时成立，此时「你设了 MOVIECLAW_TOKEN，
// 直接用就行」才是对的下一步，而「去有终端的机器上配对」是白跑一趟。
func TestLoginEnvGuardRunsBeforeTTYCheck(t *testing.T) {
	quiet(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	t.Setenv("MOVIECLAW_TOKEN", "mclaw_令牌")

	previous := stdinIsTTY
	stdinIsTTY = func() bool { return false }
	defer func() { stdinIsTTY = previous }()

	err := runLogin(&Settings{Server: "http://192.168.1.10:3000"}, "")
	var cliErr *clierr.Error
	if !asCliError(err, &cliErr) {
		t.Fatalf("应当是 CLI 错误：%v", err)
	}
	if !strings.Contains(cliErr.Message, "遮蔽") {
		t.Errorf("非交互环境下也该先说环境变量的事：%q", cliErr.Message)
	}
}

// TestLoginNonTTYPointsAtManualToken 校验非 TTY 的提示指向网页上真实存在的入口。
//
// 这条提示曾经指向一个没有创建按钮的页面，照做走不通。
func TestLoginNonTTYPointsAtManualToken(t *testing.T) {
	quiet(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	t.Setenv("MOVIECLAW_TOKEN", "")

	previous := stdinIsTTY
	stdinIsTTY = func() bool { return false }
	defer func() { stdinIsTTY = previous }()

	err := runLogin(&Settings{Server: "http://192.168.1.10:3000"}, "")
	var cliErr *clierr.Error
	if !asCliError(err, &cliErr) || cliErr.ExitCode != clierr.Usage {
		t.Fatalf("应当以用法错误退出：%v", err)
	}
	for _, want := range []string{"手工创建令牌", "MOVIECLAW_SERVER", "MOVIECLAW_TOKEN"} {
		if !strings.Contains(cliErr.Hint, want) {
			t.Errorf("提示里缺少 %q：%s", want, cliErr.Hint)
		}
	}
}

// ---------------------------------------------------------------------------
// 登录设备（docs/design/login-devices.md §4、§8）
// ---------------------------------------------------------------------------

// captureStderr 把过程提示收进缓冲区，供断言「对用户说了什么」。
func captureStderr(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	previous := output.Stderr
	output.Stderr = &buf
	t.Cleanup(func() { output.Stderr = previous })
	return &buf
}

// fakePairing 是一台能完成配对的模拟服务端，记下客户端发来的关键请求。
type fakePairing struct {
	URL string
	// authorize 收到的请求体
	authorize map[string]any
	// DELETE /auth/devices/current 收到的 Authorization，按到达顺序
	revokes []string
}

// pairingServer 模拟一台能完成配对的服务端：authorize 回执与兑换结果由用例给出，
// DELETE /auth/devices/current 一律回 revokeStatus。
func pairingServer(t *testing.T, grant, token string, revokeStatus int) *fakePairing {
	t.Helper()
	fake := &fakePairing{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/api/v1/health":
			_, _ = w.Write([]byte(`{"status":"ok","service":"movieclaw"}`))
		case r.URL.Path == "/api/v1/auth/device/authorize":
			_ = json.NewDecoder(r.Body).Decode(&fake.authorize)
			_, _ = w.Write([]byte(`{"success":true,"code":"OK","message":"","data":` + grant + `}`))
		case r.URL.Path == "/api/v1/auth/device/token":
			_, _ = w.Write([]byte(`{"success":true,"code":"OK","message":"","data":` + token + `}`))
		case r.Method == http.MethodDelete && r.URL.Path == "/api/v1/auth/devices/current":
			fake.revokes = append(fake.revokes, r.Header.Get("Authorization"))
			w.WriteHeader(revokeStatus)
			if revokeStatus < 400 {
				_, _ = w.Write([]byte(`{"success":true,"code":"OK","message":"已注销","data":null}`))
			} else {
				_, _ = w.Write([]byte(`{"success":false,"code":"UNAUTHORIZED","message":"登录凭证无效或已被注销"}`))
			}
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	fake.URL = server.URL
	return fake
}

// startPairing 以「有终端、不真等」的方式跑一遍 mclaw login。配置目录由用例
// 自己指定（要预置旧令牌的用例得先写进去）。
func startPairing(t *testing.T, server string) error {
	t.Helper()
	t.Setenv("MOVIECLAW_TOKEN", "")
	previousTTY, previousSleep := stdinIsTTY, sleep
	stdinIsTTY = func() bool { return true }
	sleep = func(time.Duration) {}
	t.Cleanup(func() { stdinIsTTY, sleep = previousTTY, previousSleep })
	return runLogin(&Settings{Server: server, Timeout: 5 * time.Second}, "mclaw@test")
}

// TestLoginReportsDeviceAndEchoesApprover 走一遍完整配对：authorize 带上安装标识、
// 系统架构与版本；给人的是带配对码的链接；成功后说清令牌是谁的身份。
func TestLoginReportsDeviceAndEchoesApprover(t *testing.T) {
	stderr := captureStderr(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	fake := pairingServer(t,
		`{"user_code":"MCLW-7F3K","device_code":"dc-1","interval":1,"expires_in":60,
		  "verification_uri":"http://nas/settings/devices",
		  "verification_uri_complete":"http://nas/settings/devices?code=MCLW-7F3K"}`,
		`{"token":"mclaw_new","client_name":"mclaw@test","client_type":"cli","granted_by":"alice"}`,
		http.StatusOK,
	)

	if err := startPairing(t, fake.URL); err != nil {
		t.Fatalf("配对失败：%v", err)
	}

	id, err := config.InstallationID()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"client_type":     "cli",
		"client_name":     "mclaw@test",
		"installation_id": id,
		"platform":        clientPlatform(runtime.GOOS, runtime.GOARCH),
		"client_version":  api.Version,
	}
	for key, value := range want {
		if got := fake.authorize[key]; got != value {
			t.Errorf("authorize 的 %s = %v，期望 %q", key, got, value)
		}
	}
	out := stderr.String()
	if !strings.Contains(out, "http://nas/settings/devices?code=MCLW-7F3K") {
		t.Errorf("没有给出带配对码的链接：\n%s", out)
	}
	if !strings.Contains(out, "由 alice 批准") {
		t.Errorf("没有回显批准者（令牌就是他的身份）：\n%s", out)
	}
	if token, _ := config.LoadToken(fake.URL); token != "mclaw_new" {
		t.Errorf("令牌没有落盘：%q", token)
	}
	if len(fake.revokes) != 0 {
		t.Errorf("首次配对没有旧令牌，不该发注销请求：%v", fake.revokes)
	}
}

// TestClientPlatformIsReadable 校验上报的平台是人认得出的写法：批准页和设备列表上
// 写着 darwin，多数人认不出这是一台 Mac。
func TestClientPlatformIsReadable(t *testing.T) {
	for _, tc := range []struct{ goos, goarch, want string }{
		{"darwin", "arm64", "macOS · arm64"},
		{"linux", "amd64", "Linux · amd64"},
		{"windows", "arm64", "Windows · arm64"},
		{"freebsd", "amd64", "freebsd · amd64"}, // 分发目标之外的系统保持原名
	} {
		if got := clientPlatform(tc.goos, tc.goarch); got != tc.want {
			t.Errorf("clientPlatform(%q, %q) = %q，期望 %q", tc.goos, tc.goarch, got, tc.want)
		}
	}
}

// TestLoginRevokesPreviousLocalToken 校验重新配对时，覆盖本地之前先用旧令牌注销它自己。
//
// 同一个人重配，服务端已按安装标识替换掉旧令牌（这里回 401）；换了人批准，旧令牌
// 不会被替换，不注销就成了本机再也拿不出来、却一直有效的孤儿。注销成不成都不能
// 影响这次登录。
func TestLoginRevokesPreviousLocalToken(t *testing.T) {
	grant := `{"user_code":"MCLW-7F3K","device_code":"dc-1","interval":1,"expires_in":60,
	  "verification_uri":"http://nas/settings/devices"}`
	token := `{"token":"mclaw_new","client_name":"mclaw@test","client_type":"cli","granted_by":"bob"}`
	for _, tc := range []struct {
		name   string
		status int
	}{
		{"换了人批准：旧令牌仍有效", http.StatusOK},
		{"同一个人重配：旧令牌已被服务端替换", http.StatusUnauthorized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			quiet(t)
			t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
			fake := pairingServer(t, grant, token, tc.status)
			if err := config.SaveToken(fake.URL, "mclaw_old"); err != nil {
				t.Fatal(err)
			}

			if err := startPairing(t, fake.URL); err != nil {
				t.Fatalf("注销旧令牌的结果不该影响登录：%v", err)
			}
			if len(fake.revokes) != 1 || fake.revokes[0] != "Bearer mclaw_old" {
				t.Errorf("应当用旧令牌注销一次：%v", fake.revokes)
			}
			if saved, _ := config.LoadToken(fake.URL); saved != "mclaw_new" {
				t.Errorf("新令牌没有落盘：%q", saved)
			}
		})
	}
}

// TestLoginFallsBackForOlderServer 校验老版本服务端（回执里没有带码链接、兑换结果
// 没有批准者）照样能配对，链接退回不带码的批准页。
func TestLoginFallsBackForOlderServer(t *testing.T) {
	stderr := captureStderr(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	fake := pairingServer(t,
		`{"user_code":"MCLW-7F3K","device_code":"dc-1","interval":1,"expires_in":60,
		  "verification_uri":"http://nas/settings/devices"}`,
		`{"token":"mclaw_new","client_name":"mclaw@test","client_type":"cli"}`,
		http.StatusNotFound, // 老服务端没有注销接口（本用例也没有旧令牌，不会用到）
	)

	if err := startPairing(t, fake.URL); err != nil {
		t.Fatalf("配对失败：%v", err)
	}
	out := stderr.String()
	if !strings.Contains(out, "请在浏览器打开：http://nas/settings/devices\n") {
		t.Errorf("没有退回不带码的批准页：\n%s", out)
	}
	if strings.Contains(out, "批准，") {
		t.Errorf("没有批准者时不该编一个出来：\n%s", out)
	}
}

// runCommand 以给定的全局标志执行一条精选命令。
func runCommand(cmd *cobra.Command, s *Settings) error {
	WithSettings(cmd, s)
	cmd.SetArgs([]string{})
	cmd.SilenceUsage = true
	cmd.SilenceErrors = true
	return cmd.Execute()
}

// revokeServer 模拟 DELETE /auth/devices/current，记下收到的 Authorization。
func revokeServer(t *testing.T, status int, body string) (string, *string) {
	t.Helper()
	var auth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete || r.URL.Path != "/api/v1/auth/devices/current" {
			http.NotFound(w, r)
			return
		}
		auth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return server.URL, &auth
}

// TestLogoutRevokesLocalTokenOnServer 校验 logout 先在服务端注销自己再删本地，
// 且注销的是凭证文件里那一枚——环境变量里的令牌可能是 Agent 或 CI 在用，不能动。
func TestLogoutRevokesLocalTokenOnServer(t *testing.T) {
	stderr := captureStderr(t)
	t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
	t.Setenv("MOVIECLAW_TOKEN", "mclaw_env")
	server, auth := revokeServer(t, http.StatusOK,
		`{"success":true,"code":"OK","message":"已注销「mclaw@test」","data":null}`)
	if err := config.SaveToken(server, "mclaw_local"); err != nil {
		t.Fatal(err)
	}

	if err := runCommand(NewLogoutCommand(), &Settings{Server: server, Timeout: 5 * time.Second}); err != nil {
		t.Fatalf("logout 失败：%v", err)
	}
	if *auth != "Bearer mclaw_local" {
		t.Errorf("注销用错了令牌：%q", *auth)
	}
	if token, _ := config.LoadToken(server); token != "" {
		t.Errorf("本地令牌没删：%q", token)
	}
	out := stderr.String()
	if strings.Contains(out, "可能仍然有效") {
		t.Errorf("服务端已经注销了，不该再让用户去网页跑一趟：\n%s", out)
	}
	if !strings.Contains(out, "unset MOVIECLAW_TOKEN") {
		t.Errorf("环境变量还在时要说破：\n%s", out)
	}
}

// TestLogoutWorksWhenServerCannotRevoke 校验服务端注销不成也照样退出：本地令牌
// 照删，并指向网页手动注销；令牌早已失效（401）则等同注销成功。
func TestLogoutWorksWhenServerCannotRevoke(t *testing.T) {
	gone := httptest.NewServer(http.NotFoundHandler())
	unreachable := gone.URL
	gone.Close() // 模拟 NAS 关机

	for _, tc := range []struct {
		name      string
		server    func(t *testing.T) string
		needsHint bool
	}{
		{"服务器连不上", func(*testing.T) string { return unreachable }, true},
		{"老版本服务端没有注销接口", func(t *testing.T) string {
			server, _ := revokeServer(t, http.StatusNotFound, `{"success":false,"code":"NOT_FOUND","message":"Not Found"}`)
			return server
		}, true},
		{"令牌早已被注销", func(t *testing.T) string {
			server, _ := revokeServer(t, http.StatusUnauthorized,
				`{"success":false,"code":"UNAUTHORIZED","message":"登录凭证无效或已被注销"}`)
			return server
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stderr := captureStderr(t)
			t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
			t.Setenv("MOVIECLAW_TOKEN", "")
			server := tc.server(t)
			if err := config.SaveToken(server, "mclaw_local"); err != nil {
				t.Fatal(err)
			}

			if err := runCommand(NewLogoutCommand(), &Settings{Server: server, Timeout: 5 * time.Second}); err != nil {
				t.Fatalf("服务端注销不成不该让 logout 失败：%v", err)
			}
			if token, _ := config.LoadToken(server); token != "" {
				t.Errorf("本地令牌没删：%q", token)
			}
			if got := strings.Contains(stderr.String(), "「设置 → 设备」里注销"); got != tc.needsHint {
				t.Errorf("是否指向网页手动注销：%v，期望 %v\n%s", got, tc.needsHint, stderr.String())
			}
		})
	}
}

// TestStatusShowsCurrentDevice 校验 status 在身份后面给出当前设备；拿不到时
// （老版本服务端、Agent 的内部令牌）整项不出现，也不让 status 失败。
func TestStatusShowsCurrentDevice(t *testing.T) {
	for _, tc := range []struct {
		name    string
		status  int
		current string
		want    any
	}{
		{"设备令牌", http.StatusOK,
			`{"success":true,"code":"OK","message":"","data":{"id":"ld-3","kind":"cli","kind_label":"命令行","name":"mclaw@nas"}}`,
			"mclaw@nas（命令行）"},
		{"不是登录设备", http.StatusNotFound,
			`{"success":false,"code":"NOT_FOUND","message":"当前登录不是设备凭证"}`,
			nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			quiet(t)
			t.Setenv("MOVIECLAW_CONFIG_DIR", t.TempDir())
			t.Setenv("MOVIECLAW_TOKEN", "mclaw_x")
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				switch r.URL.Path {
				case "/api/v1/health":
					_, _ = w.Write([]byte(`{"status":"ok","service":"movieclaw"}`))
				case "/api/v1/auth/me":
					_, _ = w.Write([]byte(`{"success":true,"code":"OK","message":"","data":{"username":"alice","nickname":"Alice"}}`))
				case "/api/v1/auth/devices/current":
					w.WriteHeader(tc.status)
					_, _ = w.Write([]byte(tc.current))
				default:
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			var stdout bytes.Buffer
			previous := output.Stdout
			output.Stdout = &stdout
			defer func() { output.Stdout = previous }()

			settings := &Settings{Server: server.URL, Output: "json", Timeout: 5 * time.Second}
			if err := runCommand(NewStatusCommand(), settings); err != nil {
				t.Fatalf("status 失败：%v", err)
			}
			var payload map[string]any
			if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
				t.Fatalf("输出不是 JSON：%v\n%s", err, stdout.String())
			}
			if payload["identity"] != "Alice" {
				t.Errorf("身份不对：%v", payload["identity"])
			}
			if payload["device"] != tc.want {
				t.Errorf("device = %v，期望 %v", payload["device"], tc.want)
			}
		})
	}
}
