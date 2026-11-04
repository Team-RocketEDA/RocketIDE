// Takes pictures of the running app, for checking its screens and for the README: node screenshots.mjs <url> <folder>
// CI runs it against the container. Each screen is tried on its own, so one failure still leaves the others.
import { mkdirSync } from "node:fs";
import { chromium } from "playwright";

const [base, out] = process.argv.slice(2);
mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1500, height: 950 } });
page.on("pageerror", (error) => console.log("page error:", error.message));
const post = (path, body) => page.request.post(base + path, body ? { data: body } : undefined);

async function shot(name, step) {
  try {
    await step();
    await page.screenshot({ path: `${out}/${name}.png` });
    console.log("took", name);
  } catch (error) {
    console.log("FAILED", name, String(error).slice(0, 200));
  }
}
async function open(project, surface) {
  await post(`/api/projects/${project}/open`);
  // A full load: changing only the # wouldn't restart the app on the project just opened.
  await page.goto("about:blank");
  await page.goto(`${base}/#${surface}`);
  await page.waitForTimeout(3500);
}

await shot("home", async () => {
  await post("/api/project/close");
  await page.goto("about:blank");
  await page.goto(base);
  await page.waitForSelector(".home-card");
  await page.waitForTimeout(1500);
});
await shot("new-project", async () => {
  await page.click(".home-new");
  await page.fill(".home-dialog textarea", "An 8-bit counter with enable and reset");
  await page.waitForTimeout(300);
});
await shot("overview", () => open("albert-chip-demo", "overview"));
await shot("diagrams", async () => {
  await open("albert-chip-demo", "diagrams");
  await page.waitForSelector(".block-diagram svg", { timeout: 30000 });
  await page.waitForTimeout(1500);
});
await shot("block-inside", async () => {
  await page.selectOption(".block-diagram-head select", "layer_etched");
  await page.waitForTimeout(600);
});
await shot("diagrams-gallery", async () => {
  await page.locator(".diagram-gallery").scrollIntoViewIfNeeded();
  await page.waitForTimeout(2500);
});
await shot("diagram-open", async () => {
  await page.locator(".diagram-card", { hasText: "mobilellm" }).first().click();
  await page.waitForTimeout(2500);
});
await shot("layout", async () => {
  await open("albert-chip-demo", "layout");
  await page.waitForTimeout(6000);
});
await shot("lesson", async () => {
  await page.request.post(`${base}/api/projects`, { data: { name: "lesson-1-rc-filter", template: "lesson-1-rc-filter" } });
  await open("lesson-1-rc-filter", "overview");
  await page.waitForTimeout(4000);
});
await shot("schematic", () => open("lesson-1-rc-filter", "schematic"));
await shot("plots", async () => {
  await post("/api/project/checks/run");
  await open("lesson-1-rc-filter", "plots");
});
// The Live build page, while the scripted test model "builds" a counter (see test-model.py).
await shot("live-start", async () => {
  await post("/api/project/close");
  await page.goto("about:blank");
  await page.goto(base);
  await page.click(".home-new");
  await page.fill(".home-dialog textarea", "An 8-bit counter with enable and reset");
  await page.click(".home-dialog .primary-button");
  await page.waitForSelector(".composer textarea:not([disabled])", { timeout: 90000 });
  await page.waitForTimeout(1000);
});
// Send the request, then keep approving what the assistant asks to change, and take pictures along the way.
await page.click(".composer button.send").catch((error) => console.log("FAILED send", String(error).slice(0, 160)));
const pictures = { 12: "live-counter", 24: "live-top", 36: "live-schematic", 56: "live-done" };
for (let second = 0; second <= 60; second++) {
  const approve = page.getByRole("button", { name: "Approve" }).first();
  if (await approve.isVisible().catch(() => false)) await approve.click().catch(() => undefined);
  if (pictures[second]) await shot(pictures[second], async () => undefined);
  await page.waitForTimeout(1000);
}
await shot("live-pick-blocks", async () => {
  await page.locator(".live-step", { hasText: "counter_top" }).first().click();
  await page.waitForTimeout(800);
  await page.locator(".block-node").first().click();
  await page.waitForTimeout(400);
});
await browser.close();
