import assert from "node:assert/strict";
import test from "node:test";

import { guessKind } from "../lib/server-addresses.ts";

test("预判内外网：与服务端 host_kind 同口径", () => {
  for (const url of [
    "http://192.168.1.10:3300",
    "http://10.0.0.2",
    "http://172.20.1.2:3000",
    "http://nas:3000",
    "http://nas.local",
    "https://router.home.arpa",
    "http://[fd00::1]:3000",
  ]) {
    assert.equal(guessKind(url), "lan", url);
  }
  for (const url of [
    "https://movie.example.com:8888",
    "https://nas.home.example.com",
    "http://8.8.8.8",
    "http://100.80.1.2:3000",
    "http://[2408:8207::1]",
  ]) {
    assert.equal(guessKind(url), "wan", url);
  }
});

test("不是完整地址时不预判", () => {
  assert.equal(guessKind(""), null);
  assert.equal(guessKind("nas.home.example.com"), null);
});
