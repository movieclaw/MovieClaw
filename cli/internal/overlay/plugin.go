package overlay

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/movieclaw/movieclaw/cli/internal/api"
	"github.com/movieclaw/movieclaw/cli/internal/clierr"
	"github.com/movieclaw/movieclaw/cli/internal/flagx"
	"github.com/movieclaw/movieclaw/cli/internal/jsonval"
	"github.com/movieclaw/movieclaw/cli/internal/output"
	"github.com/spf13/cobra"
)

// pluginManifestName 是插件包根目录的清单（docs/design/plugin-phase3.md §2）。
const pluginManifestName = "movieclaw-plugin.toml"

// NewPluginGroup 构造 `mclaw plugin`：插件开发者工具（打包、开发循环）。
//
// 安装、批准、回滚、卸载这些管理操作在生成命令 `mclaw app plugins packages …` 里；
// 这里只放写插件的人才用得到的两件事。
func NewPluginGroup() *cobra.Command {
	group := &cobra.Command{
		Use:   "plugin",
		Short: "插件开发：打包成 .mcplugin、连到服务器边改边试",
		Long: `插件开发者工具（docs/design/plugin-phase3.md §7）。

  mclaw plugin pack ./my-plugin       打包成 .mcplugin
  mclaw plugin dev  ./my-plugin       连到服务器：改一次代码就重新打包、上传、批准、加载

管理已安装的插件包用 mclaw app plugins packages …`,
		RunE:         func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
		SilenceUsage: true,
	}
	group.AddCommand(newPluginPackCommand())
	group.AddCommand(newPluginDevCommand())
	return group
}

// pluginManifest 是打包时关心的清单字段；完整校验以服务器为准。
type pluginManifest struct {
	ID      string
	Version string
	Entry   string
}

var tomlString = regexp.MustCompile(`^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*"([^"]*)"\s*(#.*)?$`)

// readPluginManifest 读出 [plugin] 段的 id / version / entry，并检查入口模块在不在。
func readPluginManifest(dir string) (pluginManifest, error) {
	var manifest pluginManifest
	file, err := os.Open(filepath.Join(dir, pluginManifestName))
	if err != nil {
		return manifest, clierr.Usagef("%s 下没有 %s", dir, pluginManifestName).
			WithHint("插件目录根部要有清单，格式见 docs/design/plugin-phase3.md §2")
	}
	defer file.Close()
	section := ""
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.Trim(line, "[] ")
			continue
		}
		if section != "plugin" {
			continue
		}
		if match := tomlString.FindStringSubmatch(line); match != nil {
			switch match[1] {
			case "id":
				manifest.ID = match[2]
			case "version":
				manifest.Version = match[2]
			case "entry":
				manifest.Entry = match[2]
			}
		}
	}
	for name, value := range map[string]string{
		"id": manifest.ID, "version": manifest.Version, "entry": manifest.Entry,
	} {
		if value == "" {
			return manifest, clierr.Usagef("%s 的 [plugin] 段缺少 %s", pluginManifestName, name)
		}
	}
	module := filepath.Join(dir, manifest.Entry+".py")
	pkg := filepath.Join(dir, manifest.Entry, "__init__.py")
	if !fileExists(module) && !fileExists(pkg) {
		return manifest, clierr.Usagef("找不到入口模块 %s.py 或 %s/__init__.py", manifest.Entry, manifest.Entry)
	}
	return manifest, nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// skipInPackage 是不进包的文件：缓存、版本库、系统垃圾、以前打的包。
func skipInPackage(rel string, entry fs.DirEntry) bool {
	name := entry.Name()
	if entry.IsDir() {
		return name == "__pycache__" || name == ".git" || name == ".venv" || name == "node_modules" ||
			(strings.HasPrefix(name, ".") && rel != ".")
	}
	return strings.HasSuffix(name, ".pyc") || strings.HasSuffix(name, ".mcplugin") ||
		name == ".DS_Store" || strings.HasPrefix(name, "._")
}

// packageFiles 列出要进包的文件（相对路径，排好序，结果稳定）。软链接一律拒绝：服务器也不收。
func packageFiles(dir string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, path)
		if skipInPackage(rel, entry) {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.Type()&fs.ModeSymlink != 0 {
			return clierr.Usagef("插件目录里不能有软链接：%s", rel)
		}
		if !entry.IsDir() {
			files = append(files, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Strings(files)
	return files, err
}

var manifestVersion = regexp.MustCompile(`(?m)^(\s*version\s*=\s*)"[^"]*"`)

// buildPluginPackage 打包；version 非空时改写清单里的版本（开发循环用）。
func buildPluginPackage(dir, version string) ([]byte, pluginManifest, error) {
	manifest, err := readPluginManifest(dir)
	if err != nil {
		return nil, manifest, err
	}
	files, err := packageFiles(dir)
	if err != nil {
		return nil, manifest, err
	}
	var buf bytes.Buffer
	archive := zip.NewWriter(&buf)
	for _, rel := range files {
		content, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(rel)))
		if err != nil {
			return nil, manifest, clierr.Usagef("读取 %s 失败：%v", rel, err)
		}
		if rel == pluginManifestName && version != "" {
			content = manifestVersion.ReplaceAll(content, []byte(`${1}"`+version+`"`))
		}
		writer, err := archive.CreateHeader(&zip.FileHeader{Name: rel, Method: zip.Deflate})
		if err != nil {
			return nil, manifest, clierr.New("打包失败：%v", err)
		}
		if _, err := writer.Write(content); err != nil {
			return nil, manifest, clierr.New("打包失败：%v", err)
		}
	}
	if err := archive.Close(); err != nil {
		return nil, manifest, clierr.New("打包失败：%v", err)
	}
	if version != "" {
		manifest.Version = version
	}
	return buf.Bytes(), manifest, nil
}

func newPluginPackCommand() *cobra.Command {
	var outputFile string
	cmd := &cobra.Command{
		Use:   "pack <插件目录>",
		Short: "把插件目录打包成 .mcplugin",
		Long: `把插件目录打包成 .mcplugin（zip），供 mclaw app plugins packages upload 或网页上传。

依赖请放进插件目录的 vendor/（安装时不联网、不跑 pip）；__pycache__、.git、隐藏文件不进包；
软链接直接拒绝。清单的完整校验（SDK、契约、宿主操作、路径授权）在上传时由服务器做。

示例：

    mclaw plugin pack ./group-blocklist
    mclaw plugin pack ./group-blocklist --output-file dist/blocklist.mcplugin`,
		Args:         cobra.ExactArgs(1),
		SilenceUsage: true,
		RunE: func(_ *cobra.Command, args []string) error {
			data, manifest, err := buildPluginPackage(args[0], "")
			if err != nil {
				return err
			}
			target := outputFile
			if target == "" {
				target = fmt.Sprintf("%s-%s.mcplugin", manifest.ID, manifest.Version)
			}
			if err := os.WriteFile(target, data, 0o644); err != nil {
				return clierr.Usagef("写入 %s 失败：%v", target, err)
			}
			output.Info("已打包 %s v%s → %s（%d 字节）", manifest.ID, manifest.Version, target, len(data))
			return nil
		},
	}
	cmd.Flags().StringVar(&outputFile, "output-file", "", "输出文件（缺省 <id>-<version>.mcplugin）")
	return cmd
}

// dirFingerprint 是目录内容的指纹（路径 + 大小 + 修改时间）：变了才重新打包。
func dirFingerprint(dir string) (string, error) {
	files, err := packageFiles(dir)
	if err != nil {
		return "", err
	}
	hash := sha1.New()
	for _, rel := range files {
		info, err := os.Stat(filepath.Join(dir, filepath.FromSlash(rel)))
		if err != nil {
			continue
		}
		fmt.Fprintf(hash, "%s|%d|%d\n", rel, info.Size(), info.ModTime().UnixNano())
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// devVersion 给开发版本加后缀：服务器不接受重复安装同一版本，每次改动都是新版本。
func devVersion(base string, now time.Time) string {
	if i := strings.IndexAny(base, "-+"); i >= 0 {
		base = base[:i]
	}
	return fmt.Sprintf("%s-dev.%d", base, now.Unix())
}

func newPluginDevCommand() *cobra.Command {
	var interval time.Duration
	var allowInline, once bool
	cmd := &cobra.Command{
		Use:   "dev <插件目录>",
		Short: "开发循环：改一次代码就重新打包、上传、批准、加载",
		Long: `把插件目录连到服务器边改边试：每次文件变化都重新打包（版本加 -dev.<时间戳> 后缀）、
上传、按插件申请的权限批准、当场加载；起不来时服务器自动回到上一版并告诉你原因。

批准等于授予插件申请的全部宿主操作与路径——只对自己的开发服务器用。看插件日志：
mclaw logs tail -f

示例：

    mclaw plugin dev ./group-blocklist
    mclaw plugin dev ./group-blocklist --once      # 只装一次就退出（脚本 / CI 用）`,
		Args: cobra.ExactArgs(1),
	}
	flagx.Var(cmd.Flags(), &interval, "interval", time.Second, "检查文件变化的间隔（秒）")
	cmd.Flags().BoolVar(&allowInline, "allow-inline", false, "插件申请在主进程里运行时，确认允许")
	cmd.Flags().BoolVar(&once, "once", false, "装一次就退出，不监视文件变化")

	return withOverrides(cmd, []string{"interval", "allow-inline", "once"},
		func(s *Settings, _ *cobra.Command, args []string) error {
			client, err := s.NewAPI()
			if err != nil {
				return err
			}
			dir := args[0]
			if once {
				return devInstall(client, dir, allowInline)
			}
			stop := make(chan os.Signal, 1)
			signal.Notify(stop, os.Interrupt)
			defer signal.Stop(stop)
			last := ""
			ticker := time.NewTicker(interval)
			defer ticker.Stop()
			for {
				current, err := dirFingerprint(dir)
				if err != nil {
					return err
				}
				if current != last {
					last = current
					if err := devInstall(client, dir, allowInline); err != nil {
						output.Info("✗ %v（改好后会自动重试）", err)
					}
				}
				select {
				case <-stop:
					output.Info("（已停止）")
					return nil
				case <-ticker.C:
				}
			}
		})
}

// devInstall 打包 → 上传 → 按申请批准 → 报告结果。
func devInstall(client *api.Client, dir string, allowInline bool) error {
	data, manifest, err := buildPluginPackage(dir, devVersion(readVersion(dir), time.Now()))
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp("", "mclaw-plugin-*.mcplugin")
	if err != nil {
		return clierr.New("创建临时文件失败：%v", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := io.Copy(tmp, bytes.NewReader(data)); err != nil {
		tmp.Close()
		return clierr.New("写临时文件失败：%v", err)
	}
	tmp.Close()
	uploaded, err := client.Upload("POST", "/app/plugins/packages", nil, tmp.Name())
	if err != nil {
		return err
	}
	body := map[string]any{
		"version":      manifest.Version,
		"operations":   nonNil(jsonval.Array(jsonval.At(uploaded, "operations"))),
		"paths":        nonNil(jsonval.Array(jsonval.At(uploaded, "paths"))),
		"allow_inline": allowInline,
	}
	result, err := client.Request("POST", "/app/plugins/packages/"+url.PathEscape(manifest.ID)+"/approve", nil, body)
	if err != nil {
		return err
	}
	if jsonval.Str(jsonval.At(result, "status")) == "active" {
		output.Info("✓ %s v%s 已加载（%s）", manifest.ID, manifest.Version, time.Now().Format("15:04:05"))
		return nil
	}
	return clierr.New("v%s 没能运行，服务器已回到 v%s：%s", manifest.Version,
		jsonval.Str(jsonval.At(result, "version")), jsonval.Str(jsonval.At(result, "error")))
}

// nonNil 让空列表序列化成 []，而不是 null（服务器的请求模型不收 null）。
func nonNil(items []any) []any {
	if items == nil {
		return []any{}
	}
	return items
}

func readVersion(dir string) string {
	manifest, err := readPluginManifest(dir)
	if err != nil {
		return "0.0.0"
	}
	return manifest.Version
}
