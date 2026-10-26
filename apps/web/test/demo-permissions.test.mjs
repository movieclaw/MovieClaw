import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import test from "node:test";

// 仅替代 React 会话 Hook 的依赖；权限计算仍从业务模块原样导入。
const hooks = registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@/lib/session") {
      return {
        url: "data:text/javascript,export function useSession() { throw new Error('unexpected hook'); }",
        shortCircuit: true,
      };
    }
    if (specifier.startsWith("@/lib/")) {
      return nextResolve(new URL(`../${specifier.slice(2)}.ts`, import.meta.url).href, context);
    }
    return nextResolve(specifier, context);
  },
});
const { accessiblePathFor, permissionsFor } = await import("../lib/permissions.ts");
hooks.deregister();

function session(role, demo, capabilities = {}) {
  return {
    username: "visitor",
    role,
    demo,
    capabilities: {
      allow_subscribe: true,
      allow_search: true,
      allow_direct_download: true,
      ...capabilities,
    },
  };
}

test("演示站超管与成员都不能搜索 PT、下载或手动选种，订阅预览仍可用", () => {
  for (const role of ["admin", "member"]) {
    const permissions = permissionsFor(session(role, true));
    assert.equal(permissions.canSubscribe, true);
    assert.equal(permissions.canSearchTorrents, false);
    assert.equal(permissions.canDirectDownload, false);
    assert.equal(permissions.canGrabForSubscription, false);
  }
});

test("普通部署手动选种同时要求订阅、PT 搜索与下载，搜索权与媒体库管理权独立", () => {
  assert.equal(permissionsFor(session("admin", false)).canGrabForSubscription, true);
  const member = permissionsFor(session("member", false));
  assert.equal(member.canSearchTorrents, true);
  assert.equal(member.canManageLibraries, false);
  assert.equal(member.canGrabForSubscription, true);
  for (const capability of ["allow_subscribe", "allow_search", "allow_direct_download"]) {
    assert.equal(
      permissionsFor(session("member", false, { [capability]: false })).canGrabForSubscription,
      false,
    );
  }
});

test("无订阅与 PT 搜索权的演示成员仍可进入媒体库搜索", () => {
  const member = session("member", true, { allow_subscribe: false, allow_search: false });
  assert.equal(accessiblePathFor(member, "/search?vertical=library"), "/search?vertical=library");
  assert.equal(accessiblePathFor(member, "/activity"), "/library");
});
