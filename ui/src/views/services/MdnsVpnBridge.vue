<template>
  <div>
    <tlt-form title="mDNS VPN Bridge — Status" sid="mdns-vpn-bridge-status"
      :model="status || {}" custom-save>
      <tlt-form-model-item v-if="error" label="Status">
        <span>{{ error }}</span>
      </tlt-form-model-item>
      <template v-if="status">
        <tlt-form-model-item label="Interface" help="Local network interface used to receive and announce mDNS packets, with its current IPv4 address.">
          <tlt-dummy-value :value="`${status.lan_if} (${status.lan_ip})`" />
        </tlt-form-model-item>
        <tlt-form-model-item label="Peer" help="Remote mDNS VPN Bridge instance reached over the VPN. This is the other relay, not a discovered device.">
          <tlt-dummy-value :value="`${status.peer}:${status.peer_port}`" />
        </tlt-form-model-item>
        <tlt-form-model-item label="LAN → peer filter" help="Current forwarding policy for mDNS packets sent from this LAN to the remote relay.">
          <tlt-dummy-value :value="status.lan2peer" />
        </tlt-form-model-item>
        <tlt-form-model-item label="Peer → LAN filter" help="Current forwarding policy for packets received from the remote relay and announced on this LAN.">
          <tlt-dummy-value :value="status.peer2lan" />
        </tlt-form-model-item>
        <tlt-form-model-item label="Uptime" help="Time since the local relay process started. Restarting the service resets this value and its traffic counters.">
          <tlt-dummy-value :value="status.uptime" />
        </tlt-form-model-item>
        <tlt-form-model-item label="Sent to peer" help="Packets and bytes forwarded from this LAN to the remote relay since startup. Dropped packets are counted separately.">
          <tlt-dummy-value :value="status.to_peer" />
        </tlt-form-model-item>
        <tlt-form-model-item label="Sent to LAN" help="Packets and bytes announced on this LAN from the remote relay since startup. Dropped packets are counted separately.">
          <tlt-dummy-value :value="status.to_lan" />
        </tlt-form-model-item>
      </template>
      <tlt-form-model-item label="Actions" help="Refresh the displayed status without restarting the relay or changing its configuration.">
        <tlt-button type="secondary" @click="loadStatus">Refresh</tlt-button>
      </tlt-form-model-item>
    </tlt-form>

    <tlt-form ref="configuration" title="mDNS VPN Bridge — Configuration"
      sid="mdns-vpn-bridge-config" :model="form" custom-save
      help="Save &amp; Apply commits these settings to UCI; the relay reloads itself through its procd config-change trigger. It does not restart the router or the VPN.">
      <tlt-form-item-switch v-model="form.enabled" label="Enable" prop="enabled"
        help="Enable the local mDNS relay. Turning this off and selecting Save &amp; Apply stops the relay; it does not disconnect the VPN." />
      <tlt-form-item-select v-model="form.lan_if" label="LAN interface"
        prop="lan_if" :options="interfaceOptions" required
        help="Select the local LAN where devices should be discovered. Only broadcast/multicast interfaces with an IPv4 address are listed. Select the LAN interface, not the VPN tunnel." />
      <tlt-form-item-input v-model="form.peer" label="Peer address (overlay)"
        prop="peer" placeholder="100.x.y.z" required
        help="IPv4 address of the other mDNS VPN Bridge instance, reachable over your VPN. For Tailscale, use the remote relay host's Tailscale IP (usually 100.x.y.z), not this router's address or a discovered device. The remote relay must point back to this router." />
      <tlt-form-item-input v-model="form.peerport" label="Link port"
        prop="peerport" placeholder="53530" required
        help="UDP port used between the two relays. Both ends must use the same port (default 53530), and the VPN/firewall must allow it. This is not the standard mDNS port 5353." />
      <tlt-form-item-select v-model="form.lan2peer" label="LAN → peer"
        prop="lan2peer" :options="filterOptions"
        help="Choose which local mDNS packets to forward to the remote relay. Queries only forwards discovery requests; All traffic also forwards answers and announcements. Queries only can reduce VPN traffic." />
      <tlt-form-item-select v-model="form.peer2lan" label="Peer → LAN"
        prop="peer2lan" :options="filterOptions"
        help="Choose which incoming mDNS packets to announce on this LAN. All traffic includes discovery answers and announcements; Queries only forwards requests. Filtering out answers can prevent local clients from discovering remote devices." />
      <tlt-form-item-input v-model="form.services" label="Service allowlist"
        prop="services" placeholder="_http,_esphomelib,_ipp"
        help="Optional comma-separated DNS-SD service filters for LAN → peer traffic, for example _http,_esphomelib,_ipp. Leave empty to allow all service types. Incoming peer → LAN traffic is not restricted by this list. Filters can hide services needed by your applications." />
      <tlt-form-item-input v-model="form.stats" label="Stats interval"
        prop="stats" placeholder="300s"
        help="Interval between traffic summaries in the system log, for example 300s, 5m or 1h. A nonzero value requires a unit (s, m or h); a bare number such as 300 is rejected. Use 0 or 0s to disable periodic summaries. This does not set the page refresh interval." />
      <tlt-form-model-item v-if="message" label="Result">
        <span role="status">{{ message }}</span>
      </tlt-form-model-item>
      <tlt-form-model-item label="Restart service" help="Restart the relay using the last saved configuration. Unsaved edits are not applied. Discovery is briefly interrupted and traffic counters reset; the VPN stays connected.">
        <tlt-button type="secondary" @click="restart">Restart service</tlt-button>
      </tlt-form-model-item>
      <template #applyButton>
        <div class="flex justify-end">
          <tlt-button @click="save">Save &amp; Apply</tlt-button>
        </div>
      </template>
    </tlt-form>
  </div>
</template>

<script>
// The RutOS WebUI injects $axios and the tlt-* components globally; nothing is
// imported here.
//
// Native ConfigService contract for a general section: GET /config returns a
// data array whose single resource carries a server-assigned "id" (the general
// section resolves to the id "general" on RutOS 7.25.3). The native PUT
// validator (api/put_logic `_PUT_validate_id`) requires every element of the PUT
// data array to carry that id; an element without a string id is rejected with
// "'id' is required." (HTTP 422). A general_section does NOT make the request
// singular (that needs the `global_settings` flag or a sid in the URL), so the
// id must be echoed back verbatim and is never invented here.
function pick(obj, key, depth = 0) {
  if (!obj || typeof obj !== "object" || depth > 4) return undefined;
  if (Object.prototype.hasOwnProperty.call(obj, key)) return obj[key];
  for (const value of Object.values(obj)) {
    const hit = pick(value, key, depth + 1);
    if (hit !== undefined) return hit;
  }
  return undefined;
}

// Native config responses are an array of resources under "data"; tolerate a
// single-object response from older firmware.
function configResource(res) {
  const data = pick(res, "data");
  if (Array.isArray(data)) return data[0] || {};
  if (data && typeof data === "object") return data;
  return res && typeof res === "object" ? res : {};
}

// Mirror of the backend stats validator (see api/services/mdns_vpn_bridge.lua):
// "0"/"0s" disable summaries; a nonzero interval needs a unit. Rejecting here
// keeps an invalid value from being sent at all, and the entered value is never
// normalized.
const STATS_MESSAGE = "Stats interval requires a unit: use 300s, 5m or 1h; use 0 to disable summaries.";

export default {
  data() {
    return {
      status: null,
      error: "",
      message: "",
      configId: "",
      filterOptions: [["query", "Queries only"], ["all", "All traffic"]],
      interfaces: [],
      form: {
        enabled: false,
        lan_if: "",
        peer: "",
        peerport: "53530",
        lan2peer: "all",
        peer2lan: "all",
        services: "",
        stats: "",
      },
    };
  },
  computed: {
    interfaceOptions() {
      const options = this.interfaces.map(item => [item.name, `${item.name} (${item.address})`]);
      // Preserve a saved interface that disappeared; never silently select another.
      if (this.form.lan_if && !this.interfaces.some(item => item.name === this.form.lan_if)) {
        options.push([this.form.lan_if, `${this.form.lan_if} (unavailable)`]);
      }
      return options;
    },
  },
  mounted() {
    this.loadInterfaces();
    this.loadConfig();
    this.loadStatus();
  },
  methods: {
    async loadInterfaces() {
      try {
        const res = await this.$axios.get("/api/mdns_vpn_bridge_f/interfaces");
        const interfaces = pick(res, "interfaces");
        this.interfaces = Array.isArray(interfaces) ? interfaces : [];
      } catch (e) {
        this.message = this.requestError(e, "Could not load LAN interfaces.");
      }
    },
    // Pull only the human-readable detail out of a RutOS error payload. Native
    // error entries look like { code, error, source, section }; some endpoints
    // nest them (a bulk envelope, a data array, an error object). Known string
    // fields are used; arbitrary objects are never stringified or exposed.
    errorDetails(data, depth = 0) {
      if (data == null || depth > 6) return "";
      if (typeof data === "string") return data.trim();
      if (Array.isArray(data)) {
        return data.map(item => this.errorDetails(item, depth + 1)).filter(Boolean).join("; ");
      }
      if (typeof data !== "object") return "";
      const stringOf = (...keys) => {
        for (const key of keys) {
          const value = data[key];
          if (typeof value === "string" && value.trim()) return value.trim();
        }
        return "";
      };
      const parts = [];
      const message = stringOf("error", "message", "msg", "detail", "reason");
      const source = stringOf("source", "field", "section", "option");
      if (message) parts.push(source ? `${source}: ${message}` : message);
      for (const key of ["errors", "messages", "data", "details", "fields"]) {
        if (data[key] != null && typeof data[key] === "object") {
          const nested = this.errorDetails(data[key], depth + 1);
          if (nested) parts.push(nested);
        }
      }
      if (data.error != null && typeof data.error === "object") {
        const nested = this.errorDetails(data.error, depth + 1);
        if (nested) parts.push(nested);
      }
      return parts.join("; ");
    },
    requestError(error, fallback) {
      const status = error && error.response ? error.response.status : undefined;
      const details = this.errorDetails(error && error.response ? error.response.data : undefined);
      return [fallback, status ? `HTTP ${status}.` : "", details].filter(Boolean).join(" ");
    },
    statsProblem(value) {
      if (value === "0" || value === "0s" || /^\d+[smh]$/.test(String(value))) return "";
      return STATS_MESSAGE;
    },
    async loadStatus() {
      this.error = "";
      try {
        const res = await this.$axios.get("/api/mdns_vpn_bridge_f/status");
        const running = pick(res, "running");
        if (running === "0" || running === 0 || running === false) {
          this.status = null;
          this.error = String(pick(res, "enabled")) === "0" ? "Disabled" : "Stopped";
          return;
        }
        this.status = {
          lan_if: pick(res, "lan_if") || "-",
          lan_ip: pick(res, "lan_ip") || "-",
          peer: pick(res, "peer") || "-",
          peer_port: pick(res, "peer_port") || "-",
          lan2peer: pick(res, "lan2peer") || "-",
          peer2lan: pick(res, "peer2lan") || "-",
          uptime: pick(res, "uptime") || "-",
          to_peer: pick(res, "to_peer") || "-",
          to_lan: pick(res, "to_lan") || "-",
        };
      } catch (e) {
        this.error = this.requestError(e, "Status request failed.");
      }
    },
    async loadConfig() {
      try {
        const res = await this.$axios.get("/api/mdns_vpn_bridge_f/config");
        const resource = configResource(res);
        // Preserve the exact server-assigned resource id for the PUT envelope.
        this.configId = String(pick(resource, "id") ?? "");
        this.form = {
          enabled: String(pick(resource, "enabled")) === "1",
          lan_if: pick(resource, "lan_if") || "",
          peer: pick(resource, "peer") || "",
          peerport: pick(resource, "peerport") || "53530",
          lan2peer: pick(resource, "lan2peer") || "all",
          peer2lan: pick(resource, "peer2lan") || "all",
          services: pick(resource, "services") || "",
          // Keep the persisted value verbatim; never append a unit here.
          stats: pick(resource, "stats") ?? "",
        };
      } catch (e) {
        this.message = this.requestError(e, "Could not read the current configuration.");
      }
    },
    // Fetch the server-assigned resource id without touching the edited form.
    async fetchConfigId() {
      const res = await this.$axios.get("/api/mdns_vpn_bridge_f/config");
      return String(pick(configResource(res), "id") ?? "");
    },
    async save() {
      this.message = "";
      // Reject an invalid stats interval before sending anything: the backend
      // rejects a bare nonzero value too, so this avoids a doomed PUT.
      const statsProblem = this.statsProblem(this.form.stats);
      if (statsProblem) {
        this.message = statsProblem;
        return;
      }
      try {
        // The native PUT validator requires the resource id. Retrieve the exact
        // server value rather than guessing it; fail loudly if it is unavailable.
        if (!this.configId) {
          this.configId = await this.fetchConfigId();
        }
        if (!this.configId) {
          this.message = "Could not determine the configuration resource id. Reload the page and try again.";
          return;
        }
        const resource = {
          id: this.configId,
          enabled: this.form.enabled ? "1" : "0",
          lan_if: this.form.lan_if,
          peer: this.form.peer,
          peerport: this.form.peerport,
          lan2peer: this.form.lan2peer,
          peer2lan: this.form.peer2lan,
          services: this.form.services,
          stats: this.form.stats,
        };
        await this.$axios.put("/api/mdns_vpn_bridge_f/config", { data: [resource] });
        this.message = "Configuration saved and applied.";
        await this.loadStatus();
      } catch (e) {
        this.message = this.requestError(e, "Saving failed.");
      }
    },
    async restart() {
      this.message = "";
      try {
        const res = await this.$axios.post("/api/mdns_vpn_bridge_f/actions/restart", { data: {} });
        this.message = String(pick(res, "restarted")) === "0"
          ? "Service is disabled; it was not restarted."
          : "Service restarted.";
        await this.loadStatus();
      } catch (e) {
        this.message = this.requestError(e, "Restart failed.");
      }
    },
  },
};
</script>
