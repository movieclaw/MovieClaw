#!/usr/bin/env python3
"""把 MovieClaw iOS 端生成的 API 层（Swift）转译成 ArkTS。

源文件（由 MovieClaw 服务端 OpenAPI spec 生成，是 MovieClaw API 的权威参照）：
  - MovieClaw/apps/apple/MovieClaw/Core/API/Generated/Models.swift    → api/Models.ets
  - MovieClaw/apps/apple/MovieClaw/Core/API/Generated/Endpoints.swift → api/Endpoints.ets

转译规则与 iOS 端逐字对齐：
  - 模型字段名用 wire 名（CodingKeys 里的 snake_case），不做 camelCase 映射，
    JSON.parse(text) as X 一次转换即可用，和 Swift Decodable 语义一致
  - Swift 可选 T?  →  ArkTS `field?: T | null`（缺失与显式 null 都能表达）
  - [String: V]    →  Record<string, V>
  - typealias X = String → type X = string（MediaKind 等字符串枚举）
  - Void 返回      →  Promise<void>（走 client 的 *Void 方法，不解析 data）

用法：python3 tools/gen_api_arkts.py（在 apps/harmonyos 目录执行）
"""

import os
import re

HARMONYOS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(HARMONYOS_DIR))
MODELS_SWIFT = os.path.join(REPO_ROOT, 'apps/apple/Shared/Core/API/Generated/Models.swift')
ENDPOINTS_SWIFT = os.path.join(REPO_ROOT, 'apps/apple/Shared/Core/API/Generated/Endpoints.swift')
MODELS_OUT = os.path.join(HARMONYOS_DIR, 'entry/src/main/ets/api/Models.ets')
ENDPOINTS_OUT = os.path.join(HARMONYOS_DIR, 'entry/src/main/ets/api/Endpoints.ets')

# Swift 基础类型 → ArkTS
BASE_TYPES = {
    'String': 'string',
    'Int': 'number',
    'Int64': 'number',
    'Double': 'number',
    'Bool': 'boolean',
    'JSONValue': 'JsonValue',
}


def convert_type(swift_type):
    """Swift 类型 → (ArkTS 类型, 是否可选)。递归处理数组/字典。"""
    t = swift_type.strip()
    optional = False
    if t.endswith('?'):
        optional = True
        t = t[:-1].strip()
    m = re.match(r'^\[(.*)\]$', t, re.DOTALL)
    if m:
        inner = m.group(1).strip()
        dm = re.match(r'^String:\s*(.*)$', inner, re.DOTALL)
        if dm:
            base, _ = convert_type(dm.group(1))
            base = f'Record<string, {base}>'
        else:
            base, _ = convert_type(inner)
            base = base + '[]'
    else:
        name = t.replace('API.', '')
        base = BASE_TYPES.get(name, name)
    return base, optional


def parse_models(src):
    """解析 Models.swift → [(doc, name, kind, body)]，kind: struct|typealias。"""
    items = []
    lines = src.split('\n')
    i = 0
    n = len(lines)
    while i < n:
        # 收集文档注释
        doc = []
        while i < n and lines[i].strip().startswith('///'):
            doc.append(lines[i].strip()[3:].strip())
            i += 1
        if i >= n:
            break
        line = lines[i]
        stripped = line.strip()
        m = re.match(r'^typealias\s+(\w+)\s*=\s*(\w+)$', stripped)
        if m:
            ts, _ = convert_type(m.group(2))
            items.append(('\n'.join(doc), m.group(1), 'typealias', ts))
            i += 1
            continue
        m = re.match(r'^struct\s+(\w+)\s*:\s*[^{]*\{', stripped)
        if m:
            name = m.group(1)
            depth = line.count('{') - line.count('}')
            fields = []  # (field_doc, swift_name, swift_type)
            coding_keys = {}  # swift_name -> wire_name
            field_doc = []
            j = i + 1
            while j < n and depth > 0:
                inner = lines[j]
                inner_stripped = inner.strip()
                depth += inner.count('{') - inner.count('}')
                if depth <= 0:
                    break
                if inner_stripped.startswith('///'):
                    field_doc.append(inner_stripped[3:].strip())
                elif not inner_stripped:
                    field_doc = []
                else:
                    # Swift 关键字字段名带反引号（如 LlmPresetView 的 `protocol`），正则要吃掉
                    fm = re.match(r'^var\s+`?(\w+)`?\s*:\s*(.+?)(?:\s*=.*)?\s*$', inner_stripped)
                    if fm:
                        fields.append(('\n'.join(field_doc), fm.group(1), fm.group(2)))
                        field_doc = []
                    km = re.match(r'^case\s+`?(\w+)`?\s*(?:=\s*"([^"]+)")?\s*$', inner_stripped)
                    if km:
                        coding_keys[km.group(1)] = km.group(2) if km.group(2) else km.group(1)
                    elif not inner_stripped.startswith('enum'):
                        field_doc = []
                j += 1
            body = []
            for fdoc, sname, stype in fields:
                wire = coding_keys.get(sname, sname)
                ts, opt = convert_type(stype)
                if fdoc:
                    for dline in fdoc.split('\n'):
                        body.append(f'  /// {dline}')
                if opt:
                    body.append(f'  {wire}?: {ts} | null')
                else:
                    body.append(f'  {wire}: {ts}')
            items.append(('\n'.join(doc), name, 'struct', '\n'.join(body)))
            i = j + 1
            continue
        i += 1
    return items


def gen_models_ets(items):
    out = []
    out.append('// 由 tools/gen_api_arkts.py 从 MovieClaw iOS 端 Models.swift 自动转译，勿手改。')
    out.append('// 源文件：MovieClaw/apps/apple/MovieClaw/Core/API/Generated/Models.swift')
    out.append('// 字段名与服务器 JSON 逐字一致（snake_case），JSON.parse 后一次 as 即可用。')
    out.append("import { JsonValue } from './JsonValue';")
    out.append('')
    for doc, name, kind, body in items:
        if doc:
            for dline in doc.split('\n'):
                out.append(f'/** {dline.strip()} */')
        if kind == 'typealias':
            out.append(f'export type {name} = {body};')
        else:
            out.append(f'export interface {name} {{')
            out.append(body)
            out.append('}')
        out.append('')
    return '\n'.join(out)


_QUERY_APPEND = r'query\.append\(URLQueryItem\(name: "([^"]+)", value: "\\\((\w+)\)"\)\)'
QUERY_SCALAR_RE = re.compile(r'if let (\w+) \{ ' + _QUERY_APPEND + r' \}')
QUERY_ARRAY_RE = re.compile(r'for value in (\w+) \?\? \[\] \{ ' + _QUERY_APPEND + r' \}')
#: 必填数组查询参数（不带 `?? []` 兜底，如 uiLibraryShowcase 的 ids）。
#: 不单独认领的话会被 QUERY_REQUIRED_RE 误吃，生成 `value: value` 的坏代码。
QUERY_ARRAY_REQUIRED_RE = re.compile(r'for value in (\w+) \{ ' + _QUERY_APPEND + r' \}')
#: 无条件的 query.append —— iOS 里必填查询参数是这么写的（可选参数才包 if let）。
#: 漏掉这一种的话，所有必填查询参数都会被静默丢掉（如 playbackMarksGet 的 media_item_id、
#: searchLibraryItems 的 keyword、libraryItemsListEpisodes 的 season_number）。
QUERY_REQUIRED_RE = re.compile(_QUERY_APPEND)


def split_params(s):
    parts = []
    depth = 0
    cur = ''
    for ch in s:
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def parse_endpoints(src):
    """解析 Endpoints.swift → 端点元组列表。"""
    endpoints = []
    lines = src.split('\n')
    i = 0
    n = len(lines)
    while i < n:
        doc = []
        while i < n and lines[i].strip().startswith('///'):
            doc.append(lines[i].strip()[3:].strip())
            i += 1
        if i >= n:
            break
        stripped = lines[i].strip()
        m = re.match(r'^func\s+(\w+)\s*\((.*)\)\s+async throws\s+->\s*(.+?)\s*\{', stripped)
        if not m:
            i += 1
            continue
        name = m.group(1)
        params_src = m.group(2)
        ret_swift = m.group(3)
        # 读取函数体直到配对的 }
        depth = lines[i].count('{') - lines[i].count('}')
        body_lines = []
        j = i + 1
        while j < n and depth > 0:
            depth += lines[j].count('{') - lines[j].count('}')
            if depth <= 0:
                break
            body_lines.append(lines[j])
            j += 1
        body = '\n'.join(body_lines)
        sm = re.search(r'try await (?:send|raw)\("([A-Z]+)",\s*"((?:[^"\\]|\\.)*)"', body)
        if not sm:
            i = j + 1
            continue
        http_method, path = sm.group(1), sm.group(2)
        query_parts = []  # (wire, swift_param_name, kind)；kind ∈ optional / array / required
        covered = []      # 已被上面两种模式吃掉的区间
        for qm in QUERY_SCALAR_RE.finditer(body):
            query_parts.append((qm.group(2), qm.group(1), 'optional'))
            covered.append((qm.start(), qm.end()))
        for qm in QUERY_ARRAY_RE.finditer(body):
            query_parts.append((qm.group(2), qm.group(1), 'array'))
            covered.append((qm.start(), qm.end()))
        for qm in QUERY_ARRAY_REQUIRED_RE.finditer(body):
            query_parts.append((qm.group(2), qm.group(1), 'array'))
            covered.append((qm.start(), qm.end()))
        # 无条件 append（必填查询参数）。if let / for in 里的 append 已被上面认领，
        # 这里跳过落在那些区间内的匹配，避免同一个参数生成两遍。
        for qm in QUERY_REQUIRED_RE.finditer(body):
            if any(s <= qm.start() and qm.end() <= e for s, e in covered):
                continue
            query_parts.append((qm.group(1), qm.group(2), 'required'))
        # iOS 有两条调用路径：`send(...)` 拆信封取 data，`raw(...)` 直接解响应体。
        # 后端少数「裸」接口（如 /health）返回扁平对象，用 send 会拆成 undefined——
        # 早先生成器把两者一律当 send，health 因此在客户端永远解析失败（见 §10）。
        is_raw = re.search(r'try await raw\(', body) is not None
        bm = re.search(r'send\("[A-Z]+", "(?:[^"\\]|\\.)*"(?:, body: ([^,)]+))?', body)
        body_expr = bm.group(1).strip() if bm and bm.group(1) else None
        params = []  # (pname, swift_type, optional)
        if params_src.strip():
            for p in split_params(params_src):
                pm = re.match(r'^(\w+):\s*(.+?)\s*(?:=\s*nil)?$', p.strip())
                if not pm:
                    raise SystemExit(f'无法解析参数: {p!r} (func {name})')
                stype = pm.group(2).strip()
                params.append((pm.group(1), stype, stype.endswith('?')))
        is_void = ret_swift.strip() == 'Void'
        endpoints.append(('\n'.join(doc), name, params, ret_swift, http_method, path,
                          query_parts, body_expr, is_void, is_raw))
        i = j + 1
    return endpoints


CLIENT_METHOD = {'GET': 'get', 'POST': 'post', 'PUT': 'put', 'DELETE': 'del', 'PATCH': 'patch'}


def collect_referenced_types(endpoints):
    """收集端点签名/返回值引用的所有自定义模型名，用于 import。"""
    refs = set()
    for _, _, params, ret_swift, _, _, _, _, _, _ in endpoints:
        for src in [ret_swift] + [p[1] for p in params]:
            for name in re.findall(r'API\.(\w+)', src):
                refs.add(name)
    return sorted(refs)


def gen_endpoints_ets(endpoints, model_names):
    out = []
    out.append(
        '// 由 tools/gen_api_arkts.py 从 MovieClaw iOS 端 Endpoints.swift 自动转译，勿手改。'
    )
    out.append('// 源文件：MovieClaw/apps/apple/MovieClaw/Core/API/Generated/Endpoints.swift')
    out.append('// 方法名、路径、查询参数与 iOS 端逐字一致；路径相对 /api/v1。')
    out.append('import { ApiClient, ApiQuery, QueryPair } from \'./ApiClient\';')
    out.append('import { JsonValue } from \'./JsonValue\';')
    refs = [
        t for t in collect_referenced_types(endpoints)
        if t in model_names and t != 'JSONValue'
    ]
    out.append('import {')
    for r in refs:
        out.append(f'  {r},')
    out.append("} from './Models';")
    out.append('')
    out.append('/// MovieClaw 全量业务接口（对应 iOS 端 `extension APIClient` 的生成方法）。')
    out.append('export class MovieClawApi {')
    out.append('  private client: ApiClient;')
    out.append('')
    out.append('  constructor(client: ApiClient) {')
    out.append('    this.client = client;')
    out.append('  }')
    for endpoint in endpoints:
        (doc, name, params, ret_swift, http_method, path,
         query_parts, body_expr, is_void, is_raw) = endpoint
        out.append('')
        if doc:
            for dline in doc.split('\n'):
                out.append(f'  /** {dline.strip()} */')
        sig = []
        for pname, stype, opt in params:
            ts, _ = convert_type(stype)
            sig.append(f'{pname}?: {ts}' if opt else f'{pname}: {ts}')
        if is_void:
            ret_ts = 'void'
        else:
            base, opt = convert_type(ret_swift)
            ret_ts = base + (' | null' if opt else '')
        out.append('  {}({}): Promise<{}> {{'.format(name, ', '.join(sig), ret_ts))
        client_fn = CLIENT_METHOD[http_method]
        if is_void:
            client_fn += 'Void'
        # iOS 的 raw(...) 不拆信封 → 用 rawGet（目前只有 GET 的裸接口，硬断言一下免得静默生成错）
        if is_raw:
            if http_method != 'GET':
                raise SystemExit(f'raw() 目前只支持 GET：{name}')
            client_fn = 'rawGet'
        # 查询参数收集
        if query_parts:
            out.append('    const pairs: QueryPair[] = [];')
            for wire, pname, kind in query_parts:
                if kind == 'array':
                    out.append(f'    if ({pname} !== undefined && {pname} !== null) {{')
                    out.append(
                        f'      for (const item of {pname}) {{ '
                        f'pairs.push({{ key: \'{wire}\', value: item }}); }}'
                    )
                    out.append('    }')
                elif kind == 'required':
                    # 必填查询参数：直接进查询串，不做存在性判断（与 iOS 的无条件 append 一致）
                    out.append(f'    pairs.push({{ key: \'{wire}\', value: {pname} }});')
                else:
                    out.append(
                        f'    if ({pname} !== undefined && {pname} !== null) {{ '
                        f'pairs.push({{ key: \'{wire}\', value: {pname} }}); }}'
                    )
        # 路径模板（\(x) → ${x}）
        tpl = path
        for pname, _, _ in params:
            tpl = tpl.replace(f'\\({pname})', f'${{{pname}}}')
        if '\\(' in tpl:
            raise SystemExit(f'路径插值未替换完整: {tpl}')
        path_lit = f'`{tpl}`' if '${' in tpl else f"'{tpl}'"
        call_path = path_lit + (' + ApiQuery.build(pairs)' if query_parts else '')
        # 调用（GET 无 bodyText；POST/PUT/DELETE/PATCH 必须显式传 null）
        if body_expr:
            out.append(
                f'    const bodyText = ({body_expr} === undefined || {body_expr} === null)'
                f' ? null : JSON.stringify({body_expr});'
            )
            if is_void:
                out.append(f'    return this.client.{client_fn}({call_path}, bodyText);')
            else:
                out.append(f'    return this.client.{client_fn}<{ret_ts}>({call_path}, bodyText);')
        else:
            noBodyArg = 'null' if http_method != 'GET' else ''
            if is_void:
                if http_method == 'GET':
                    out.append(f'    return this.client.{client_fn}({call_path});')
                else:
                    out.append(f'    return this.client.{client_fn}({call_path}, {noBodyArg});')
            else:
                if http_method == 'GET':
                    out.append(f'    return this.client.{client_fn}<{ret_ts}>({call_path});')
                else:
                    out.append(
                        f'    return this.client.{client_fn}<{ret_ts}>({call_path}, {noBodyArg});'
                    )
        out.append('  }')
    out.append('}')
    return '\n'.join(out)


def main():
    with open(MODELS_SWIFT, encoding='utf-8') as f:
        models_src = f.read()
    with open(ENDPOINTS_SWIFT, encoding='utf-8') as f:
        endpoints_src = f.read()
    items = parse_models(models_src)
    structs = [x for x in items if x[2] == 'struct']
    aliases = [x for x in items if x[2] == 'typealias']
    print(f'模型: {len(structs)} struct, {len(aliases)} typealias')
    endpoints = parse_endpoints(endpoints_src)
    print(f'端点: {len(endpoints)}')
    model_names = set(x[1] for x in items)
    os.makedirs(os.path.dirname(MODELS_OUT), exist_ok=True)
    with open(MODELS_OUT, 'w', encoding='utf-8') as f:
        f.write(gen_models_ets(items))
    with open(ENDPOINTS_OUT, 'w', encoding='utf-8') as f:
        f.write(gen_endpoints_ets(endpoints, model_names))
    print(f'已生成: {MODELS_OUT}')
    print(f'已生成: {ENDPOINTS_OUT}')


if __name__ == '__main__':
    main()
