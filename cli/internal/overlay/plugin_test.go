package overlay

import (
	"archive/zip"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

func writePluginDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		"movieclaw-plugin.toml": "[plugin]\nid = \"acme.demo\"\ntitle = \"示例\"\nversion = \"1.2.3\"\nentry = \"demo\"\n\n[permissions]\noperations = []\n",
		"demo.py":               "VALUE = 1\n",
		"vendor/dep.py":         "X = 2\n",
		"__pycache__/demo.pyc":  "junk",
		".git/HEAD":             "junk",
		".DS_Store":             "junk",
		"old.mcplugin":          "junk",
	}
	for name, content := range files {
		path := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func zipEntries(t *testing.T, data []byte) map[string]string {
	t.Helper()
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	entries := map[string]string{}
	for _, file := range reader.File {
		rc, _ := file.Open()
		content, _ := io.ReadAll(rc)
		rc.Close()
		entries[file.Name] = string(content)
	}
	return entries
}

func TestBuildPluginPackageSkipsJunkAndKeepsVendor(t *testing.T) {
	dir := writePluginDir(t)
	data, manifest, err := buildPluginPackage(dir, "")
	if err != nil {
		t.Fatalf("打包失败：%v", err)
	}
	if manifest.ID != "acme.demo" || manifest.Version != "1.2.3" || manifest.Entry != "demo" {
		t.Fatalf("清单读错了：%+v", manifest)
	}
	entries := zipEntries(t, data)
	var names []string
	for name := range entries {
		names = append(names, name)
	}
	sort.Strings(names)
	want := "demo.py,movieclaw-plugin.toml,vendor/dep.py"
	if strings.Join(names, ",") != want {
		t.Fatalf("包里应只有 %s，实际 %v", want, names)
	}
}

func TestBuildPluginPackageRewritesDevVersion(t *testing.T) {
	dir := writePluginDir(t)
	version := devVersion("1.2.3", time.Unix(1700000000, 0))
	if version != "1.2.3-dev.1700000000" {
		t.Fatalf("开发版本号不对：%s", version)
	}
	data, manifest, err := buildPluginPackage(dir, version)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Version != version {
		t.Fatalf("返回的版本应是开发版本，实际 %s", manifest.Version)
	}
	if !strings.Contains(zipEntries(t, data)["movieclaw-plugin.toml"], `version = "1.2.3-dev.1700000000"`) {
		t.Fatal("包里的清单版本没有改写")
	}
	// 已经是开发版本时只换后缀，不叠加
	if devVersion("1.2.3-dev.1", time.Unix(5, 0)) != "1.2.3-dev.5" {
		t.Fatal("开发版本后缀应替换而不是叠加")
	}
}

func TestPluginManifestErrorsAreActionable(t *testing.T) {
	dir := t.TempDir()
	if _, err := readPluginManifest(dir); err == nil || !strings.Contains(err.Error(), "movieclaw-plugin.toml") {
		t.Fatalf("缺清单要说清楚，实际：%v", err)
	}
	os.WriteFile(filepath.Join(dir, "movieclaw-plugin.toml"),
		[]byte("[plugin]\nid = \"acme.x\"\nversion = \"1.0.0\"\nentry = \"missing\"\n"), 0o644)
	if _, err := readPluginManifest(dir); err == nil || !strings.Contains(err.Error(), "入口模块") {
		t.Fatalf("缺入口模块要说清楚，实际：%v", err)
	}
	os.WriteFile(filepath.Join(dir, "missing.py"), []byte(""), 0o644)
	os.Symlink("/etc/passwd", filepath.Join(dir, "link"))
	if _, _, err := buildPluginPackage(dir, ""); err == nil || !strings.Contains(err.Error(), "软链接") {
		t.Fatalf("软链接必须拒绝，实际：%v", err)
	}
}

func TestDirFingerprintChangesWithContent(t *testing.T) {
	dir := writePluginDir(t)
	first, err := dirFingerprint(dir)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := dirFingerprint(dir)
	if first != again {
		t.Fatal("没改动时指纹应不变")
	}
	os.WriteFile(filepath.Join(dir, "demo.py"), []byte("VALUE = 22\n"), 0o644)
	changed, _ := dirFingerprint(dir)
	if changed == first {
		t.Fatal("改了代码指纹应变化")
	}
	// 缓存文件变化不触发重装
	os.WriteFile(filepath.Join(dir, "__pycache__", "demo.pyc"), []byte("other"), 0o644)
	if cache, _ := dirFingerprint(dir); cache != changed {
		t.Fatal("__pycache__ 变化不应触发重装")
	}
}
