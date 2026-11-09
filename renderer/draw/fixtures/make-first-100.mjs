// Rebuilds first-100.plan.json (Glow v2, scene kinds) from first-100.words.json.
// node renderer/draw/fixtures/make-first-100.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const dir = dirname(fileURLToPath(import.meta.url));
const words = JSON.parse(readFileSync(join(dir, "first-100.words.json"), "utf8")).map((w) => w.word);
const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
const at = (phrase, from = 0) => {
  const p = phrase.split(" ").map(norm);
  for (let i = from; i < words.length; i++) if (p.every((w, j) => norm(words[i + j] ?? "") === w)) return i;
  throw new Error(`not found: ${phrase}`);
};
const cuts = [
  0, at("Most people think"), at("So they post"), at("But imagine"), at("Video one"), at("Here's what nobody"),
  at("She knows which topics"), at("That's not luck"), at("This happens because"), at("So stop asking"), words.length,
];
const text = (i) => words.slice(cuts[i], cuts[i + 1]).join(" ");
const scenes = [
  { kind: "grid", count: 12, hot: 5, title: "100 VIDEOS", labels: [{ on: "tuition.", text: "TUITION" }, { on: "content.", text: "NOT CONTENT" }] },
  { kind: "crowd", count: 7, hot: 3, goal: "EVERY VIDEO HAS TO WORK", labels: [{ on: "people", text: "MOST PEOPLE" }] },
  { kind: "feed", title: "VIDEO 1", number: { on: "gets", until: "views,", from: 0, to: 200, label: "VIEWS" }, labels: [{ on: "built", text: "NOT BUILT FOR THIS?" }] },
  { kind: "journey", who: "SOMEONE", goal: "90 DAYS", number: { on: "every", until: "months.", from: 1, to: 90, prefix: "DAY ", label: "POSTING" }, labels: [{ on: "imagine", text: "IMAGINE" }] },
  { kind: "chart", lines: [{ label: "VIEWS", shape: "late_jump" }], number: { on: "two", until: "thousand...", from: 40, to: 200000, label: "VIEWS" }, labels: [{ on: "luck.", text: "LUCK?" }] },
  { kind: "night", who: "WHAT NOBODY SEES", labels: [{ on: "stop.", text: "THE FIRST SECOND" }] },
  { kind: "machine", title: "BY VIDEO 62", items: ["WHAT THEY SAVE", "20 MINUTES"], icons: ["heart", "clock"], labels: [{ on: "font.", text: "CHOOSING A FONT" }] },
  { kind: "stairs", direction: "up", number: { on: "sixty-one", until: "for.", from: 0, to: 61, label: "VIDEOS PAID FOR IT" }, labels: [{ on: "luck.", text: "NOT LUCK" }] },
  { kind: "chart", lines: [{ label: "SKILL", shape: "rise" }, { label: "RESULTS", shape: "late_jump" }], labels: [{ on: "later,", text: "LATER. ALL AT ONCE." }] },
  { kind: "globe", goal: "THE ONE THAT DOES", title: "STILL BE HERE?", labels: [{ on: "viral.", text: "WILL IT GO VIRAL?" }] },
].map((s, i) => ({ text: text(i), ...s }));
writeFileSync(join(dir, "first-100.plan.json"), JSON.stringify({ title: "Your first 100 videos", caption: "", scenes }, null, 1));
console.log(scenes.map((s) => `${s.kind}:${s.text.split(" ").length}w`).join("  "));
