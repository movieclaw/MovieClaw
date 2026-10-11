package tree

import (
	"strings"
	"testing"
)

// TestBooleanFlagsInExamplesUseEquals 自动合成的示例里，布尔参数一律写成 --flag=true：
// 照抄 --flag true 会被 cobra 当成多出来的位置参数，命令直接报用法错误。
func TestBooleanFlagsInExamplesUseEquals(t *testing.T) {
	found := false
	for _, op := range IterOperations(loadSpec(t)) {
		if !op.Generable() {
			continue
		}
		line := exampleLine(op)
		for _, f := range op.BodyFields {
			if f.Required && f.Schema.Type == "boolean" && f.Kind != "json" {
				found = true
				if !strings.Contains(line, f.FlagName()+"=true") {
					t.Errorf("%s 的示例里布尔参数没写成 %s=true：%s", op.OperationID, f.FlagName(), line)
				}
			}
		}
		if op.OperationID == "app.plugins.switch" && !strings.Contains(line, "--enabled=true") {
			t.Errorf("app.plugins.switch 示例应为 --enabled=true：%s", line)
		}
	}
	if !found {
		t.Fatal("spec 里应至少有一个必填布尔参数的命令（如 app plugins switch）")
	}
}
