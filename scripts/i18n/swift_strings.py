"""Find Swift string literals, including literals nested inside interpolations."""

from collections.abc import Iterator
from dataclasses import dataclass


@dataclass
class Literal:
    start: int
    end: int
    text: str  # literal characters only; interpolated code is left out


def literals(source: str) -> Iterator[Literal]:
    """Yield every string literal in source order of their end positions (nested ones first).

    Comments are skipped, `\\(...)` interpolations are scanned as code so the literals inside them
    are reported on their own, and raw strings (`#"..."#`) are treated as plain text.
    """
    yield from _code(source, 0, len(source), None)


def _code(source: str, index: int, limit: int, stop: list[int] | None) -> Iterator[Literal]:
    depth = 0
    while index < limit:
        char = source[index]
        if source.startswith("//", index):
            newline = source.find("\n", index)
            index = limit if newline < 0 else newline
            continue
        if source.startswith("/*", index):
            close = source.find("*/", index + 2)
            index = limit if close < 0 else close + 2
            continue
        if char == "#" or char == '"':
            hashes = 0
            while index + hashes < limit and source[index + hashes] == "#":
                hashes += 1
            if index + hashes < limit and source[index + hashes] == '"':
                found: list[int] = [0]
                yield from _string(source, index, hashes, limit, found)
                index = found[0]
                continue
            index += max(hashes, 1)
            continue
        if stop is not None:
            if char == "(":
                depth += 1
            elif char == ")":
                if depth == 0:
                    stop[0] = index + 1
                    return
                depth -= 1
        index += 1
    if stop is not None:
        stop[0] = limit


def _string(
    source: str, start: int, hashes: int, limit: int, found: list[int]
) -> Iterator[Literal]:
    index = start + hashes
    multiline = source.startswith('"""', index)
    quote = '"""' if multiline else '"'
    index += len(quote)
    closing = quote + "#" * hashes
    escape = "\\" + "#" * hashes
    text: list[str] = []
    while index < limit:
        if source.startswith(closing, index):
            index += len(closing)
            found[0] = index
            yield Literal(start, index, "".join(text))
            return
        if source.startswith(escape, index):
            after = index + len(escape)
            if after < limit and source[after] == "(":
                stop = [0]
                yield from _code(source, after + 1, limit, stop)
                index = stop[0]
                continue
            text.append(source[index : after + 1])
            index = after + 1
            continue
        if not multiline and source[index] == "\n":
            break  # unterminated: stop at the line end rather than swallowing the file
        text.append(source[index])
        index += 1
    found[0] = index
    yield Literal(start, index, "".join(text))
