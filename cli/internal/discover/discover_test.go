package discover

import (
	"encoding/json"
	"net"
	"reflect"
	"strings"
	"testing"
	"time"
)

// responder 起一个照服务端 services/lan_discovery.py 协议应答的临时监听者：
// 按询问分别回自家应答或 Jellyfin 应答（不传就不应答那一句，模拟旧服务器）。
func responder(t *testing.T, native, jellyfin []string) {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		t.Skipf("跳过：无法监听 UDP（%v）", err)
	}
	previous := port
	port = conn.LocalAddr().(*net.UDPAddr).Port
	t.Cleanup(func() { port = previous; conn.Close() })

	go func() {
		buf := make([]byte, 4096)
		for {
			n, addr, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			// 暗号大小写不敏感，这里按服务端的口径只做包含判断
			query := strings.ToLower(string(buf[:n]))
			replies := jellyfin
			if strings.Contains(query, "who is movieclawserver?") {
				replies = native
			}
			for _, reply := range replies {
				_, _ = conn.WriteToUDP([]byte(reply), addr)
			}
		}
	}()
}

func jellyfinReply(address, name string) string {
	raw, _ := json.Marshal(map[string]any{
		"Address": address, "Name": name, "Id": "x", "EndpointAddress": nil,
	})
	return string(raw)
}

func nativeReply(name string, addresses ...string) string {
	raw, _ := json.Marshal(map[string]any{
		"type": "movieclaw.discovery", "version": 1, "instance_id": "x",
		"name": name, "server_version": "0.41.0", "addresses": addresses,
	})
	return string(raw)
}

// 新服务器两句都答：同一来源合并成一台，自家应答的地址在前，来源 IP 拼出的兜底在后。
// 广播在本机回环上收到的来源 IP 不固定，按 Find 返回的来源推导期望值。
func TestFindMergesBothRepliesFromOneServer(t *testing.T) {
	responder(t,
		[]string{nativeReply("客厅 NAS", "http://192.168.1.10:3300", "https://m.example.com")},
		[]string{jellyfinReply("http://172.17.0.2:3000", "客厅 NAS")},
	)
	found, err := Find(time.Second)
	if err != nil {
		t.Fatalf("查找失败：%v", err)
	}
	if len(found) != 1 {
		t.Fatalf("期望合并成 1 台，实际 %d：%+v", len(found), found)
	}
	got := found[0]
	source := strings.TrimSuffix(strings.TrimPrefix(got.Candidates[len(got.Candidates)-1], "http://"), ":3000")
	want := []string{
		"http://192.168.1.10:3300",
		"https://m.example.com",
		"http://172.17.0.2:3000",
		"http://" + source + ":3300",
		"http://" + source + ":3000",
	}
	if got.Name != "客厅 NAS" || got.Address != want[0] || !reflect.DeepEqual(got.Candidates, want) {
		t.Errorf("合并结果不对：%+v\n期望候选 %v", got, want)
	}
}

// 旧服务器只认 Jellyfin 的询问：照样找得到。
func TestFindWorksWithOldServers(t *testing.T) {
	responder(t, nil, []string{jellyfinReply("http://10.0.0.5:3000", "旧版")})
	found, err := Find(time.Second)
	if err != nil {
		t.Fatalf("查找失败：%v", err)
	}
	if len(found) != 1 || found[0].Address != "http://10.0.0.5:3000" || found[0].Name != "旧版" {
		t.Fatalf("旧服务器的应答没解析出来：%+v", found)
	}
}

// TestFindReturnsEmptyWhenNobodyAnswers 校验「没找到」不是错误：局域网里没有、
// 或者不在同一网段都是正常情况，调用方据空结果回落到手工给地址。
func TestFindReturnsEmptyWhenNobodyAnswers(t *testing.T) {
	previous := port
	// 随手占一个空端口号：没人在上面应答
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		t.Skipf("跳过：无法分配端口（%v）", err)
	}
	port = conn.LocalAddr().(*net.UDPAddr).Port
	conn.Close()
	t.Cleanup(func() { port = previous })

	found, err := Find(300 * time.Millisecond)
	if err != nil {
		t.Fatalf("没人应答不该报错：%v", err)
	}
	if len(found) != 0 {
		t.Fatalf("不该找到任何东西：%+v", found)
	}
}

// TestParseReplyIgnoresGarbage 校验非 JSON 或缺 Address 的应答被跳过——
// 局域网里什么都可能往这个端口发；自家应答的空地址列表是合法的。
func TestParseReplyIgnoresGarbage(t *testing.T) {
	for _, raw := range []string{"不是 JSON", `{"Name":"缺地址"}`, `{"Address":""}`, `[1,2]`} {
		if _, ok := parseReply([]byte(raw)); ok {
			t.Errorf("垃圾应答没有被过滤：%s", raw)
		}
	}
	got, ok := parseReply([]byte(`{"type":"movieclaw.discovery","addresses":["", 5, "http://a:1"]}`))
	if !ok || !got.native || !reflect.DeepEqual(got.addresses, []string{"http://a:1"}) {
		t.Errorf("自家应答解析不对：%+v", got)
	}
	got, ok = parseReply([]byte(`{"type":"movieclaw.discovery","addresses":[]}`))
	if !ok || len(got.addresses) != 0 {
		t.Errorf("空地址列表也该算合法应答：%+v %v", got, ok)
	}
}

func TestCandidatesForFallsBackToSourceIP(t *testing.T) {
	got := candidatesFor(nil, "192.168.1.10")
	if !reflect.DeepEqual(got, []string{"http://192.168.1.10:3000"}) {
		t.Errorf("没有地址时只剩来源 IP + 3000：%v", got)
	}
	got = candidatesFor([]string{"ftp://x", "https://m.example.com/", "http://192.168.1.10:3000/"}, "192.168.1.10")
	want := []string{"https://m.example.com", "http://192.168.1.10:3000"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("候选地址不对：%v，期望 %v", got, want)
	}
}

func TestBroadcastOfComputesSubnetAddress(t *testing.T) {
	_, ipnet, _ := net.ParseCIDR("192.168.1.42/24")
	ipnet.IP = net.ParseIP("192.168.1.42")
	if got := broadcastOf(ipnet); got.String() != "192.168.1.255" {
		t.Errorf("广播地址算错了：%v", got)
	}
}

// TestBroadcastTargetsAlwaysIncludeLimited 校验受限广播永远在列表里：
// 逐网卡枚举可能一无所获（容器、无网卡环境），那时它是唯一的出路。
func TestBroadcastTargetsAlwaysIncludeLimited(t *testing.T) {
	targets := broadcastTargets()
	if len(targets) == 0 || !targets[0].IP.Equal(net.IPv4bcast) {
		t.Fatalf("首个目标应当是 255.255.255.255：%+v", targets)
	}
}
