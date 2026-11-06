// Test the native config contract without a browser, router calls or service
// changes. The native PUT validator (api/put_logic `_PUT_validate_id`) requires
// every element of the data array to carry the server-returned resource id, so
// the view must echo the id it read from GET /config (never invent one).
//
// Error surfacing mirrors the real RutOS error entries { code, error, source,
// section } and the client-side stats validation mirrors the backend validator.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../ui/src/views/services/MdnsVpnBridge.vue", import.meta.url), "utf8");
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];
const context = {};
vm.runInNewContext(script.replace("export default", "globalThis.component ="), context);
const component = context.component;
const instance = component.data();
for (const [name, method] of Object.entries(component.methods)) instance[name] = method.bind(instance);

// Real firmware (RutOS 7.25.3): the general section resolves to id "general".
const resource = {
  id: "general", enabled: "1", lan_if: "br-lan", peer: "100.64.0.1", peerport: "53530",
  lan2peer: "all", peer2lan: "query", services: "", stats: "300s",
};
let configResponse = { data: [resource] };
const requests = [];
instance.$axios = {
  async get(url) {
    requests.push({ method: "GET", url });
    if (url.endsWith("/config")) return configResponse;
    if (url.endsWith("/status")) {
      return { running: "1", enabled: "1", lan_if: "br-lan", lan_ip: "192.0.2.2", peer: "100.64.0.1", peer_port: "53530", lan2peer: "all", peer2lan: "query", uptime: "1h02m", to_peer: "-", to_lan: "-" };
    }
    if (url.endsWith("/interfaces")) return { data: { interfaces: [{ name: "br-lan", address: "192.0.2.1" }] } };
    return {};
  },
  async put(url, body) { requests.push({ method: "PUT", url, body }); return {}; },
  async post(url, body) { requests.push({ method: "POST", url, body }); return { restarted: "1", enabled: "1" }; },
};
const putCount = () => requests.filter(r => r.method === "PUT").length;
const lastPut = () => requests.filter(r => r.method === "PUT").at(-1);

// Config GET parses the data array and preserves the server id + raw stats.
await instance.loadConfig();
assert.equal(instance.form.enabled, true);
assert.equal(instance.form.lan_if, "br-lan");
assert.equal(instance.form.peer2lan, "query");
assert.equal(instance.configId, "general");
assert.equal(instance.form.stats, "300s", "persisted stats must be kept verbatim");

// Config PUT echoes the exact server-returned id (the fix for HTTP 422
// "'id' is required.") and keeps stats verbatim.
instance.form.enabled = false;
instance.form.peer = "100.64.0.9";
await instance.save();
const put = lastPut();
assert.equal(put.url, "/api/mdns_vpn_bridge_f/config");
assert.equal(Object.keys(put.body).join(), "data");
assert.ok(Array.isArray(put.body.data) && put.body.data.length === 1);
assert.equal(put.body.data[0].id, "general", "PUT must carry the server resource id");
assert.equal(put.body.data[0].enabled, "0");
assert.equal(put.body.data[0].peer, "100.64.0.9");
assert.equal(put.body.data[0].peerport, "53530");
assert.equal(put.body.data[0].stats, "300s", "PUT must not normalize stats");
assert.equal(instance.message, "Configuration saved and applied.");

// Client-side validation: a bare nonzero stats value is rejected with concrete
// guidance and NO PUT is sent (no silent normalization, no doomed request).
instance.form.stats = "300";
let before = putCount();
await instance.save();
assert.equal(putCount(), before, "invalid bare stats must not send a PUT");
assert.match(instance.message, /requires a unit/, "guidance must name the missing unit");
assert.match(instance.message, /300s, 5m or 1h/, "guidance must show valid examples");

// "0" and "0s" disable summaries and are valid; the entered value is sent
// verbatim (never rewritten to a different token).
for (const value of ["0", "0s"]) {
  instance.form.stats = value;
  before = putCount();
  await instance.save();
  assert.equal(putCount(), before + 1, `${value} must be accepted and sent`);
  assert.equal(lastPut().body.data[0].stats, value, `${value} must be sent verbatim`);
}
instance.form.stats = "300s";

// No guessing: when the server returns no id, the view must NOT fabricate one
// and must not send a doomed PUT; it surfaces an error instead.
instance.configId = "";
configResponse = { data: [{ enabled: "1" }] };
before = putCount();
await instance.save();
assert.equal(putCount(), before, "must not send a PUT without a server id");
assert.match(instance.message, /resource id/, "missing id must be reported, not guessed");
configResponse = { data: [resource] };
instance.configId = "general";

// Accurate error surface for a rejected save: the native error entry
// { code, error, source } must reach the user with its field name, not as a
// bare status code.
instance.$axios.put = async () => { throw { response: { status: 422, data: { errors: [{ code: 103, error: "Invalid option", source: "stats" }] } } }; };
await instance.save();
assert.equal(instance.message, "Saving failed. HTTP 422. stats: Invalid option");

// message-only entries (no `error` key) and a top-level `error` string are read.
instance.$axios.put = async () => { throw { response: { status: 500, data: { errors: [{ message: "restart failed", source: "service" }] } } }; };
await instance.save();
assert.equal(instance.message, "Saving failed. HTTP 500. service: restart failed");
instance.$axios.put = async () => { throw { response: { status: 422, data: { error: "plain detail" } } }; };
await instance.save();
assert.equal(instance.message, "Saving failed. HTTP 422. plain detail");

// Nested structures (a data array wrapping error entries) are unwrapped.
instance.$axios.put = async () => { throw { response: { status: 422, data: { data: [{ errors: [{ error: "nested", source: "peer" }] }] } } }; };
await instance.save();
assert.equal(instance.message, "Saving failed. HTTP 422. peer: nested");

// Arbitrary objects are never stringified or exposed: only known detail fields.
instance.$axios.put = async () => { throw { response: { status: 500, data: { internal: { token: "secret" } } } }; };
await instance.save();
assert.equal(instance.message, "Saving failed. HTTP 500.");
assert.doesNotMatch(instance.message, /secret|token|\[object/);
instance.$axios.put = async (url, body) => { requests.push({ method: "PUT", url, body }); return {}; };

// Restart action uses the parameterless data-object envelope.
await instance.restart();
const post = requests.filter(r => r.method === "POST").at(-1);
assert.equal(post.url, "/api/mdns_vpn_bridge_f/actions/restart");
assert.equal(JSON.stringify(post.body), '{"data":{}}');
assert.equal(instance.message, "Service restarted.");
instance.$axios.post = async () => ({ restarted: "0", enabled: "0" });
await instance.restart();
assert.equal(instance.message, "Service is disabled; it was not restarted.");

// Error surface for restart, including the old bare-422 shape (a source with no
// message) which must not crash or dump an object.
instance.$axios.post = async () => { throw { response: { status: 500, data: { errors: [{ error: "service restart command failed", source: "service" }] } } }; };
await instance.restart();
assert.equal(instance.message, "Restart failed. HTTP 500. service: service restart command failed");
instance.$axios.post = async () => { throw { response: { status: 422, data: { errors: [{ code: 122, source: "Request" }] } } }; };
await instance.restart();
assert.equal(instance.message, "Restart failed. HTTP 422.");

// Status and discovered interface selection.
instance.$axios.get = async (url) => {
  if (url.endsWith("/status")) return { running: "0", enabled: "0" };
  return { data: { interfaces: [{ name: "br-lan", address: "192.0.2.1" }] } };
};
await instance.loadStatus();
assert.equal(instance.status, null);
assert.equal(instance.error, "Disabled");
instance.$axios.get = async () => ({ running: "0", enabled: "1" });
await instance.loadStatus();
assert.equal(instance.error, "Stopped");
instance.$axios.get = async () => ({ data: { interfaces: [{ name: "br-lan", address: "192.0.2.1" }] } });
await instance.loadInterfaces();
instance.form.lan_if = "br-lan";
let options = component.computed.interfaceOptions.call(instance);
assert.equal(JSON.stringify(options), '[["br-lan","br-lan (192.0.2.1)"]]');
instance.form.lan_if = "old-lan";
options = component.computed.interfaceOptions.call(instance);
assert.equal(options.at(-1)[1], "old-lan (unavailable)");
assert.equal(instance.form.lan_if, "old-lan");

assert.match(source, /this\.\$axios\.put\("\/api\/mdns_vpn_bridge_f\/config", \{ data: \[resource\] \}\)/);
assert.match(source, /id: this\.configId/);
assert.match(source, /<tlt-form-item-select v-model="form.lan_if"/);

// ---- Version display -------------------------------------------------------
// The WebUI build version is injected at build time (__UI_VERSION__ via
// vite.config.js) and is never hardcoded in the view. Without the build define
// (this vm run) it falls back to a non-version token.
assert.equal(instance.uiVersion, "unknown", "no build define must fall back, never a literal");
const buildContext = { __UI_VERSION__: "9.9.9" };
vm.runInNewContext(script.replace("export default", "globalThis.component = "), buildContext);
assert.equal(buildContext.component.data().uiVersion, "9.9.9", "uiVersion must come from the injected build token");
// No hardcoded semver *literal* anywhere in the component source (a firmware
// number in a comment is fine; a quoted version value is not).
assert.doesNotMatch(script, /["'`]\d+\.\d+\.\d+["'`]/, "the view must not hardcode a version literal");

// Relay version reflects the *running* process reported by the API; Unknown when
// stopped, absent or unreported (never invented).
const relay = component.computed.relayVersion;
instance.status = { relay_version: "0.5.1" };
assert.equal(relay.call(instance), "0.5.1");
for (const missing of ["", "-", undefined]) {
  instance.status = { relay_version: missing };
  assert.equal(relay.call(instance), "Unknown", `relay_version=${JSON.stringify(missing)} must show Unknown`);
}
instance.status = null;
assert.equal(relay.call(instance), "Unknown", "stopped relay must show Unknown");

// loadStatus carries relay_version through verbatim, and stays empty when absent.
instance.$axios.get = async () => ({ running: "1", enabled: "1", relay_version: "0.5.1", lan_if: "br-lan", lan_ip: "192.0.2.2", peer: "100.64.0.1", peer_port: "53530", lan2peer: "all", peer2lan: "query", uptime: "1h02m", to_peer: "-", to_lan: "-" });
await instance.loadStatus();
assert.equal(instance.status.relay_version, "0.5.1");
assert.equal(relay.call(instance), "0.5.1");
instance.$axios.get = async () => ({ running: "1", enabled: "1", lan_if: "br-lan" });
await instance.loadStatus();
assert.equal(instance.status.relay_version, "", "a missing field must not invent a version");
assert.equal(relay.call(instance), "Unknown");

// Both rows render with native components; the build version is wired from
// package.json by the Vite config.
assert.match(source, /<tlt-form-model-item label="Relay version"[\s\S]*?<tlt-dummy-value :value="relayVersion" \/>/);
assert.match(source, /<tlt-form-model-item label="WebUI version"[\s\S]*?<tlt-dummy-value :value="uiVersion" \/>/);
assert.match(script, /typeof __UI_VERSION__ !== "undefined"/);
const viteConfig = readFileSync(new URL("../ui/vite.config.js", import.meta.url), "utf8");
const pkg = JSON.parse(readFileSync(new URL("../ui/package.json", import.meta.url), "utf8"));
assert.match(viteConfig, /__UI_VERSION__:\s*JSON\.stringify\(pkg\.version\)/, "vite.config.js must define __UI_VERSION__ from package.json");
assert.ok(/^\d+\.\d+\.\d+$/.test(pkg.version), "package.json version must be semver");
console.log("PASS: config data-array GET/PUT with server id echo, client stats validation, native error surface (field/message/nested), no-guess guard, verbatim stats, restart envelope, status and interface selection, build-derived WebUI version and running-relay version mapping (mock transport)");
