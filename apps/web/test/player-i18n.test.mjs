import assert from "node:assert/strict";
import test from "node:test";

import { planAudioOptions } from "../lib/player/audio-tracks.ts";
import { displayModes } from "../lib/player/display-mode.ts";
import { qualityOptions } from "../lib/player/quality.ts";
import { rememberedChoicesNotice } from "../lib/player/remembered-choices.ts";
import { planSubtitleTracks } from "../lib/player/subtitles.ts";
import { skipLabel, skipName } from "../lib/player/timeline.ts";

test("player menus render each locale without caching a previous language", () => {
  const tracks = [
    { ref: "embedded:0", language: "eng", codec: "aac", channels: 2, is_default: true },
    { ref: "embedded:1", language: null, codec: "aac", channels: 3, is_default: false },
  ];
  assert.equal(planAudioOptions(tracks, "en")[0].label, "English · AAC · Stereo");
  assert.equal(planAudioOptions(tracks, "en")[1].label, "Audio track 1 · AAC · 3 channels");
  assert.equal(planAudioOptions(tracks, "zh-Hans")[0].label, "英语 · AAC · 立体声");
  assert.equal(planAudioOptions(tracks, "en")[0].label, "English · AAC · Stereo");
  assert.equal(displayModes("en")[0].label, "Fit");
  assert.equal(displayModes("zh-Hans")[0].label, "完整显示");
  assert.equal(qualityOptions("en")[0].label, "Auto");
  assert.equal(qualityOptions("zh-Hans")[0].label, "自动");
});

test("subtitle metadata is translated while user titles and file names are preserved", () => {
  const plan = { track_ref: "external:My subs.srt", kind: "vtt", language: "jpn", title: "自定义标题", is_default: true, is_forced: true };
  const english = planSubtitleTracks([plan], ["/sub?token=x"], "en").options[0];
  assert.equal(english.title, "自定义标题");
  assert.equal(english.label, "自定义标题 · Text");
  assert.equal(english.detail, "Japanese · WebVTT · External · Default · Forced");
  assert.equal(english.url, "/sub?token=x&format=vtt");
  assert.equal(planSubtitleTracks([plan], [], "en").unavailable[0].reason, "The server did not provide a URL for this track");
  assert.equal(planSubtitleTracks([plan], [], "zh-Hans").unavailable[0].reason, "服务端没有给出这条轨的地址");
});

test("skip and remembered choice sentences keep their original Chinese wording", () => {
  assert.equal(skipLabel({ type: "intro" }, "en"), "Skip intro");
  assert.equal(skipName({ type: "intro" }, "zh-Hans"), "片头");
  const choices = { quality: 720, audio: "Japanese", subtitle: "Off" };
  assert.equal(rememberedChoicesNotice(choices, "en"), "Using your previous choices: Quality 720p, Audio Japanese, Subtitles Off");
  assert.equal(rememberedChoicesNotice({ quality: 720, audio: "日语", subtitle: "关闭" }, "zh-Hans"), "已沿用上次的选择：画质 720p，音轨 日语，字幕 关闭");
});
