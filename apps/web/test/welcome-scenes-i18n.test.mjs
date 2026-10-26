import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { WELCOME_SCENES, sceneText } from "../lib/welcome-scenes.ts";

test("welcome quotes are the same content data as the Apple apps", () => {
  const apple = JSON.parse(
    readFileSync(new URL("../../apple/Shared/Welcome/WelcomeQuotes.json", import.meta.url), "utf8"),
  );
  assert.deepEqual(WELCOME_SCENES, apple);
  for (const scene of WELCOME_SCENES) {
    assert.ok(scene.filmEnglish, scene.film);
    assert.ok(scene.original ?? scene.english, `${scene.film} needs an English line`);
  }
});

test("welcome quotes follow the interface language", () => {
  const casablanca = WELCOME_SCENES.find((scene) => scene.filmEnglish === "Casablanca");
  assert.deepEqual(sceneText(casablanca, "zh-Hans"), {
    headline: "我们永远拥有巴黎。",
    subline: "We'll always have Paris.",
    film: "卡萨布兰卡",
    source: "《卡萨布兰卡》1942",
  });
  assert.deepEqual(sceneText(casablanca, "en"), {
    headline: "We'll always have Paris.",
    subline: null,
    film: "Casablanca",
    source: "Casablanca, 1942",
  });

  const chinese = WELCOME_SCENES.find((scene) => scene.original === null);
  const english = sceneText(chinese, "en");
  assert.equal(english.headline, chinese.english);
  assert.equal(english.subline, chinese.line, "Chinese films keep the original line under the translation");
  assert.doesNotMatch(english.source, /[㐀-鿿]/);
});
