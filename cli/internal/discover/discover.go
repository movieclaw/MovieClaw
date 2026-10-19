// Package discover 是局域网里找 movieclaw 的最后一招。
//
// 协议见 docs/design/lan-discovery.md：往 UDP 7359 广播两句询问——自家的
// `who is MovieClawServer?`（应答一组按可信度排好的地址）与 Jellyfin 的
// `who is JellyfinServer?`（v0.40.0 及更早的服务器只认这一句，应答一个 Address）。
// 同一来源 IP 的应答合并成一台服务器。
//
// **它只是兜底，不是主路**。这些情况下发现不到，`--server` 必须一直留着：
//
//  1. 服务端停用了「局域网发现」，或 Docker 部署没映射 UDP 7359；
//  2. 跨网段、VPN、公网——广播出不去；
//  3. UDP 7359 被别的程序占了。
package discover

import (
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strconv"
	"time"
)

// probes 是服务端认的两句暗号（大小写不敏感），自家的在前。
var probes = []string{"who is MovieClawServer?", "who is JellyfinServer?"}

// defaultPort 是 docker-compose 默认映射的对外端口。
const defaultPort = 3000

// port 与服务端 services/lan_discovery.py 的 DISCOVERY_PORT 一致。
// 是变量而非常量，只为让测试能在临时端口上起应答者（7359 常被真服务占着）。
var port = 7359

// Server 是一台应答了发现请求的服务器。
type Server struct {
	// Address 是最可信的候选地址（含协议与端口），即 Candidates[0]。
	Address string
	// Name 是服务器名，用于在多台之间区分。
	Name string
	// Candidates 是按可信度排好的全部候选地址：应答里的地址 → 来源 IP +
	// 应答里出现过的端口 → 来源 IP + 3000。桥接部署下服务端报的地址未必连得上，
	// 调用方应逐个确认。
	Candidates []string
}

// reply 是一条解析后的应答。
type reply struct {
	addresses []string
	name      string
	native    bool
}

// parseReply 解析应答；不是发现应答（非 JSON、Jellyfin 应答缺 Address）时 ok 为 false。
// 自家应答的地址列表可以为空：桥接部署又没学到宿主地址时，只能靠来源 IP 拼。
func parseReply(data []byte) (reply, bool) {
	var raw map[string]any
	if json.Unmarshal(data, &raw) != nil {
		return reply{}, false
	}
	text := func(key string) string {
		value, _ := raw[key].(string)
		return value
	}
	if text("type") == "movieclaw.discovery" {
		list, _ := raw["addresses"].([]any)
		var addresses []string
		for _, item := range list {
			if value, ok := item.(string); ok && value != "" {
				addresses = append(addresses, value)
			}
		}
		return reply{addresses: addresses, name: text("name"), native: true}, true
	}
	if text("Address") == "" {
		return reply{}, false
	}
	return reply{addresses: []string{text("Address")}, name: text("Name")}, true
}

// candidatesFor 由一台服务器的全部应答地址与来源 IP 拼出候选地址（去重、保序）。
func candidatesFor(addresses []string, source string) []string {
	var list []string
	add := func(value string) {
		for _, existing := range list {
			if existing == value {
				return
			}
		}
		list = append(list, value)
	}
	var ports []int
	for _, address := range addresses {
		parsed, err := url.Parse(address)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			continue
		}
		add(parsed.Scheme + "://" + parsed.Host)
		if p, err := strconv.Atoi(parsed.Port()); err == nil {
			ports = append(ports, p)
		}
	}
	for _, p := range append(ports, defaultPort) {
		add("http://" + net.JoinHostPort(source, strconv.Itoa(p)))
	}
	return list
}

// Find 广播一次并收集 timeout 内的全部应答，同一来源 IP 合并成一台。
//
// 找不到不是错误：局域网里没有、或者根本不在同一网段，都是正常情况，
// 调用方据空结果回落到「请给地址」即可。返回 error 只表示「这次探测本身
// 没能发出去」（没有可用网卡、权限不足）。
func Find(timeout time.Duration) ([]Server, error) {
	conn, err := listen()
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	targets := broadcastTargets()
	if len(targets) == 0 {
		return nil, errors.New("没有找到可用于广播的网络接口")
	}
	var sent int
	for _, target := range targets {
		for _, probe := range probes {
			if _, err := conn.WriteToUDP([]byte(probe), target); err == nil {
				sent++
			}
		}
	}
	if sent == 0 {
		return nil, errors.New("广播发送失败（可能被防火墙拦截或缺少权限）")
	}

	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return nil, err
	}
	var sources []string
	replies := map[string][]reply{}
	buf := make([]byte, 4096)
	for {
		n, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			// 读超时即本轮结束——这是正常出口，不是失败
			break
		}
		parsed, ok := parseReply(buf[:n])
		if !ok {
			continue
		}
		source := from.IP.String()
		if _, seen := replies[source]; !seen {
			sources = append(sources, source)
		}
		replies[source] = append(replies[source], parsed)
	}
	return merge(sources, replies), nil
}

// merge 把每个来源的应答合成一台服务器：自家应答的地址与名字在前。
func merge(sources []string, replies map[string][]reply) []Server {
	var found []Server
	for _, source := range sources {
		var addresses []string
		name := ""
		for _, native := range []bool{true, false} {
			for _, item := range replies[source] {
				if item.native != native {
					continue
				}
				addresses = append(addresses, item.addresses...)
				if name == "" {
					name = item.name
				}
			}
		}
		candidates := candidatesFor(addresses, source)
		found = append(found, Server{Address: candidates[0], Name: name, Candidates: candidates})
	}
	return found
}

// broadcastTargets 收集要发往的广播地址。
//
// 除了受限广播 255.255.255.255，还要逐网卡算出定向广播地址：多网卡机器
// （有线 + 无线、Docker 网桥）上，受限广播只会从内核选的那一张网卡出去，
// 服务器恰好在另一张网卡那侧就找不到了。
func broadcastTargets() []*net.UDPAddr {
	targets := []*net.UDPAddr{{IP: net.IPv4bcast, Port: port}}
	interfaces, err := net.Interfaces()
	if err != nil {
		return targets
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagBroadcast == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok || ipnet.IP.To4() == nil {
				continue
			}
			if bcast := broadcastOf(ipnet); bcast != nil {
				targets = append(targets, &net.UDPAddr{IP: bcast, Port: port})
			}
		}
	}
	return targets
}

// broadcastOf 由地址与掩码算出该网段的定向广播地址。
func broadcastOf(ipnet *net.IPNet) net.IP {
	ip := ipnet.IP.To4()
	mask := net.IP(ipnet.Mask).To4()
	if ip == nil || mask == nil {
		return nil
	}
	bcast := make(net.IP, net.IPv4len)
	for i := range bcast {
		bcast[i] = ip[i] | ^mask[i]
	}
	return bcast
}
