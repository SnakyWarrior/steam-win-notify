/**
 * steam-win-notify - frontend
 *
 * 1) Hooks `window.NotificationStore.ProcessNotification` (Steam's central
 *    toast chokepoint). Every in-client toast - Steam updates, achievements,
 *    friend chat, trades, etc. - flows through this method.
 * 2) Subscribes to SteamClient.* callbacks for events that bypass the
 *    NotificationStore (downloads, screenshots).
 * 3) Forwards the data to the Lua backend via RPC, which fires a native
 *    Windows 11 toast.
 * 4) Exposes a Millennium settings panel to toggle Windows notifications.
 */

import { callable, definePlugin } from "@steambrew/client";
import {
  ToggleField,
} from "@steambrew/client";

const SP_REACT: any = (window as any).SP_REACT;

// Backend RPC ----------------------------------------------------------------

const callSendNotification = callable<
  [{ payload_json: string }],
  string
>("send_notification");
const callGetConfig = callable<[], string>("get_config");
const callSetConfig = callable<[{ payload: string }], string>("set_config");


type Cfg = {
  enabled: boolean;
  enabled_kinds: string[];
  app_id: string;
  cache_images: boolean;
};

let cfg: Cfg = {
  enabled: true,
  enabled_kinds: ["*"],
  app_id: "Valve.Steam",
  cache_images: true,
};

async function loadConfig() {
  try {
    const raw = await callGetConfig();
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object") {
      const kinds = Array.isArray(parsed.enabled_kinds)
        ? parsed.enabled_kinds
        : ["*"];
      cfg = {
        enabled: kinds.length > 0,
        enabled_kinds: kinds.length > 0 ? kinds : ["*"],
        app_id: typeof parsed.app_id === "string" ? parsed.app_id : "Valve.Steam",
        cache_images: !!parsed.cache_images,
      };
    }
  } catch (e) {
    console.warn("[steam-win-notify] could not load backend config:", e);
  }
}

async function saveConfig() {
  try {
    const payload = JSON.stringify({
      enabled_kinds: cfg.enabled ? cfg.enabled_kinds : [],
      app_id: cfg.app_id,
      cache_images: cfg.cache_images,
    });
    await callSetConfig({ payload });
  } catch (e) {
    console.error("[steam-win-notify] save error:", e);
  }
}

// Try native Windows notification via the browser Notification API.
// Since we run inside Steam's Chromium webhelper, this sends toasts
// under Steam's identity — no AUMID/PowerShell issues.
function notifyBrowser(title: string, body: string) {
  try {
    if (typeof Notification === "undefined") {
      console.log("[steam-win-notify] Notification API not available");
      return;
    }
    if (Notification.permission === "granted") {
      new Notification(title, { body, icon: undefined });
    } else if (Notification.permission !== "denied") {
      Notification.requestPermission().then((perm) => {
        if (perm === "granted") {
          new Notification(title, { body, icon: undefined });
        }
      });
    }
  } catch (e) {
    console.warn("[steam-win-notify] Notification API error:", e);
  }
}

async function send(payload: {
  title: string;
  body: string;
  image_url: string;
  kind: string;
}) {
  // Skip stale/generic entries from internal stores that have no content
  if (payload.kind === "generic" && payload.title === "Steam" && !payload.body) return;

  console.log(
    "[steam-win-notify] send: kind=" + payload.kind + " title=" + payload.title + " body=" + payload.body
  );

  // Browser Notification API — runs in Steam's process, no AUMID issues.
  notifyBrowser(payload.title, payload.body);

  // Backend RPC — send as JSON string to avoid RPC bridge field reordering.
  try {
    const result = await callSendNotification({ payload_json: JSON.stringify(payload) } as any);
    console.log("[steam-win-notify] RPC result:", result);
  } catch (e) {
    console.error("[steam-win-notify] RPC error:", e);
  }
}

// Kind mapping ---------------------------------------------------------------

const E_TYPE: Record<number, string> = {
  1: "chat",
  2: "friend",
  3: "invite",
  4: "achievement",
  5: "trade",
  6: "screenshot",
  7: "download",
  8: "broadcast",
  9: "purchase",
  10: "wishlist",
  11: "comment",
  12: "generic",
  13: "moderator",
  14: "gift",
  15: "party",
};

function kindFromEType(n: any): string {
  if (typeof n === "number" && E_TYPE[n]) return E_TYPE[n];
  return "generic";
}

function stringify(v: any): string {
  if (v == null) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (typeof v === "object") {
    if (typeof v.props?.children === "string") return v.props.children;
    if (Array.isArray(v.props?.children)) {
      return v.props.children
        .map((c: any) => (typeof c === "string" ? c : stringify(c)))
        .join("")
        .trim();
    }
    if (typeof v.toString === "function") {
      const s = v.toString();
      if (s && s !== "[object Object]") return s;
    }
  }
  return "";
}

function extract(toastData: any): {
  title: string;
  body: string;
  image_url: string;
  kind: string;
} {
  const raw = toastData?.data ?? toastData ?? {};
  let kind = kindFromEType(toastData?.eType ?? raw?.eType);

  // Steam notification objects have the actual payload nested under .data
  // e.g. { nNotificationID, data: { title, body, ... }, eType }
  const d = raw?.data ?? raw;

  const title =
    stringify(d?.title) ||
    stringify(d?.strTitle) ||
    stringify(raw?.title) ||
    stringify(raw?.strTitle) ||
    stringify(d?.headline) ||
    stringify(d?.strHeadline) ||
    stringify(d?.app_name) ||
    "Steam";

  const body =
    stringify(d?.body) ||
    stringify(d?.strBody) ||
    stringify(raw?.body) ||
    stringify(raw?.strBody) ||
    stringify(d?.subtext) ||
    stringify(d?.message) ||
    stringify(d?.strMessage) ||
    stringify(d?.description) ||
    "";

  const image_url =
    stringify(d?.icon) ||
    stringify(d?.logo) ||
    stringify(raw?.icon) ||
    stringify(raw?.logo) ||
    stringify(d?.strIcon) ||
    stringify(d?.strImage) ||
    stringify(d?.image_url) ||
    stringify(d?.strAvatarUrl) ||
    stringify(raw?.strIcon) ||
    "";

  // Override kind based on title/body keywords when eType is unknown
  if (kind === "generic") {
    const tl = (title + " " + body).toLowerCase();
    if (tl.includes("update") || tl.includes("download") || tl.includes("ready")) {
      kind = "download";
    } else if (tl.includes("message") || tl.includes("chat") || tl.includes("said")) {
      kind = "chat";
    } else if (tl.includes("friend") || tl.includes("online") || tl.includes("offline")) {
      kind = "friend";
    } else if (tl.includes("controller") || tl.includes("xinput") || tl.includes("gamepad") || tl.includes("xbox")) {
      kind = "controller";
    }
  }

  return { title, body, image_url, kind };
}

function shouldForward(kind: string): boolean {
  if (!cfg.enabled) return false;
  if (cfg.enabled_kinds.includes("*")) return true;
  return cfg.enabled_kinds.includes(kind);
}

// Patch NotificationStore methods using defineProperty.
let nsPatched = false;

function wrapMethod(target: any, methodName: string, handler: (...args: any[]) => boolean | void): boolean {
  const original = target[methodName];
  if (typeof original !== "function") return false;
  try {
    const wrapped = function (this: any, ...args: any[]) {
      const suppress = handler.apply(this, args) === false;
      if (suppress) return;
      return original.apply(this, args);
    };
    Object.defineProperty(target, methodName, {
      value: wrapped, writable: true, configurable: true,
    });
    return true;
  } catch {
    try {
      target[methodName] = function (this: any, ...args: any[]) {
        const suppress = handler.apply(this, args) === false;
        if (suppress) return;
        return original.apply(this, args);
      };
      return true;
    } catch { return false; }
  }
}

function patchNotificationStoreMethods(proto: any) {
  const forwardIfNew = (extracted: ReturnType<typeof extract>) => {
    const dedupKey = `${extracted.kind}:${extracted.title}:${extracted.body}`;
    if (!seenNotifs.has(dedupKey)) {
      seenNotifs.add(dedupKey);
      if (shouldForward(extracted.kind)) {
        send(extracted);
      }
    }
  };

  wrapMethod(proto, "ProcessNotification", function (...args: any[]) {
    console.log("[steam-win-notify] ProcessNotification CALLED", args.length);
    const toastData = args[1];
    const eType = args[2];
    const extracted = extract(toastData);
    forwardIfNew(extracted);
  });

  function inspect(obj: any, label: string) {
    try {
      if (!obj || typeof obj !== "object") { console.log(`[steam-win-notify] ${label}:`, typeof obj, obj); return; }
      console.log(`[steam-win-notify] ${label} keys:`, Object.keys(obj));
      console.log(`[steam-win-notify] ${label} json:`, JSON.stringify(obj).slice(0, 500));
    } catch {}
  }

  wrapMethod(proto, "OnNewNotificationReceived", function (notification: any) {
    inspect(notification, "OnNewNotificationReceived");
    const extracted = extract({ data: notification, eType: notification?.eType });
    forwardIfNew(extracted);
  });

  wrapMethod(proto, "OnNotification", function (notification: any) {
    inspect(notification, "OnNotification");
    const extracted = extract({ data: notification, eType: notification?.eType });
    forwardIfNew(extracted);
  });
}

function patchNotificationStore(): boolean {
  if (nsPatched) return true;
  const ns: any = (window as any).NotificationStore;
  console.log("[steam-win-notify] NotificationStore:", !!ns, typeof ns);
  if (!ns) return false;

  // Find the prototype that has the methods we want to hook
  let proto: any = ns;
  let depth = 0;
  while (proto && depth < 10) {
    if (typeof proto.ProcessNotification === "function") {
      patchNotificationStoreMethods(proto);

      // Log all function calls on the prototype for discovery
      try {
        const allMethods = Object.getOwnPropertyNames(proto).filter(
          (k: any) => typeof proto[k] === "function" && !k.startsWith("_")
        );
        console.log("[steam-win-notify] NotificationStore methods:", allMethods.join(", "));
      } catch {}

      nsPatched = true;
      console.log(`[steam-win-notify] Patched NotificationStore methods (depth ${depth})`);

      // Wrap all functions on the store itself with logging
      try {
        const ownMethods = Object.getOwnPropertyNames(ns).filter(
          (k: any) => typeof ns[k] === "function" && !k.startsWith("_")
        );
        for (const m of ownMethods) {
          const orig = ns[m];
          ns[m] = function (...args: any[]) {
            console.log(`[steam-win-notify] NS.${m}() called`);
            return orig.apply(this, args);
          };
        }
      } catch {}

      return true;
    }
    proto = Object.getPrototypeOf(proto);
    depth++;
  }
  return false;
}



// SteamClient.* event hooks (each registered only ONCE) ----------------------

const _scHooked = {
  notifications: false,
  achievements: false,
  downloads: false,
  screenshots: false,
  chat: false,
};


function hookSteamClient() {
  const SC: any = (window as any).SteamClient;
  console.log("[steam-win-notify] SteamClient:", !!SC);
  if (!SC) return;
  try {
    const names = Object.getOwnPropertyNames(SC);
    console.log("[steam-win-notify] SC top-level keys:", names.join(", "));
    for (const k of names) {
      const v = SC[k];
      if (v && typeof v === "object") {
        try { console.log("[steam-win-notify]   SC." + k + " methods:", Object.getOwnPropertyNames(v).filter((p: any) => typeof v[p] === "function").join(", ")); } catch {}
      }
    }
  } catch {} 

  if (
    !_scHooked.notifications &&
    SC.Notifications?.RegisterForNotifications
  ) {
    _scHooked.notifications = true;
    try {
      SC.Notifications.RegisterForNotifications((notifications: any) => {
        console.log("[steam-win-notify] SC.RegisterForNotifications callback:", notifications);
        const list = Array.isArray(notifications)
          ? notifications
          : [notifications];
        for (const n of list) {
          const { title, body, image_url, kind } = extract({
            data: n,
            eType: n?.eType,
          });
          const dedupKey = `${kind}:${title}:${body}`;
          if (seenNotifs.has(dedupKey)) continue;
          seenNotifs.add(dedupKey);
          if (!shouldForward(kind)) continue;
          send({ title, body, image_url, kind });
        }
      });
      console.log("[steam-win-notify] Hooked SteamClient.Notifications (RegisterForNotifications)");
    } catch (e) {
      console.warn("[steam-win-notify] SC.Notifications hook error:", e);
    }
  }

  if (
    !_scHooked.achievements &&
    SC.Apps?.RegisterForAchievementNotification
  ) {
    _scHooked.achievements = true;
    try {
      SC.Apps.RegisterForAchievementNotification((data: any) => {
        if (!shouldForward("achievement")) return;
        send({
          title:
            data?.strDisplayName ?? data?.strTitle ?? "Achievement Unlocked",
          body:
            data?.strDescription ??
            data?.achievement?.strDescription ??
            "",
          image_url:
            data?.achievement?.strImage ?? data?.strImage ?? "",
          kind: "achievement",
        });
      });
      console.log("[steam-win-notify] Hooked Apps.AchievementNotification");
    } catch {
      /* swallow */
    }
  }

  if (!_scHooked.downloads && SC.Downloads?.RegisterForDownloadItems) {
    _scHooked.downloads = true;
    try {
      SC.Downloads.RegisterForDownloadItems(
        (_paused: boolean, items: any[]) => {
          if (!Array.isArray(items)) return;
          for (const it of items) {
            if (!(it?.completed || it?.bCompleted)) continue;
            if (!shouldForward("download")) continue;
            send({
              title: "Download complete",
              body: it?.strName ?? it?.name ?? "A download has finished.",
              image_url: it?.strIcon ?? "",
              kind: "download",
            });
          }
        }
      );
      console.log("[steam-win-notify] Hooked Downloads");
    } catch {
      /* swallow */
    }
  }

  if (
    !_scHooked.screenshots &&
    SC.GameSessions?.RegisterForScreenshotNotification
  ) {
    _scHooked.screenshots = true;
    try {
      SC.GameSessions.RegisterForScreenshotNotification((data: any) => {
        if (!shouldForward("screenshot")) return;
        send({
          title: "Screenshot saved",
          body: data?.strGameName ?? data?.name ?? "",
          image_url: data?.strUrl ?? data?.strThumbnail ?? "",
          kind: "screenshot",
        });
      });
      console.log("[steam-win-notify] Hooked Screenshots");
    } catch {
      /* swallow */
    }
  }

  // Chat hook is brittle - mark as tried after one attempt regardless.
  if (!_scHooked.chat) {
    _scHooked.chat = true;
    try {
      const reg =
        SC.FriendSettings?.RegisterForNewMessages ??
        SC.Messaging?.RegisterForMessages;
      if (typeof reg === "function") {
        reg.call(SC.FriendSettings ?? SC.Messaging, (msg: any) => {
          if (!shouldForward("chat")) return;
          send({
            title:
              msg?.strPersonaName ??
              msg?.persona_name ??
              msg?.strFrom ??
              "Steam Chat",
            body: msg?.strMessage ?? msg?.message ?? "",
            image_url: msg?.strAvatarUrl ?? msg?.avatar_url ?? "",
            kind: "chat",
          });
        });
        console.log("[steam-win-notify] Hooked Chat");
      }
    } catch {
      /* swallow */
    }
  }

}

const seenNotifs = new Set<string>();

function forwardPendingNotifications() {
  setTimeout(async () => {
    try {
      const ns = (window as any).NotificationStore as any;
      if (!ns) return;

      function inspectItem(obj: any, label: string) {
        try {
          if (!obj || typeof obj !== "object") return;
          console.log(`[steam-win-notify] ${label} keys:`, Object.keys(obj));
          console.log(`[steam-win-notify] ${label} json:`, JSON.stringify(obj).slice(0, 400));
        } catch {}
      }

      // Try using the store's own method to get tray notifications
      if (typeof ns.GetNotificationsInTray === "function") {
        const tray = ns.GetNotificationsInTray();
        console.log("[steam-win-notify] GetNotificationsInTray():", Array.isArray(tray) ? tray.length : typeof tray);
        if (Array.isArray(tray)) {
          for (const group of tray) {
            inspectItem(group, "tray group");
            // Tray groups have { eType, notifications: [...] }
            const notifs = group?.notifications ?? (Array.isArray(group) ? group : [group]);
            if (Array.isArray(notifs)) {
              for (const n of notifs) {
                const extracted = extract(n);
                console.log("[steam-win-notify]   extracted title=" + extracted.title + " body=" + extracted.body + " kind=" + extracted.kind);
                const dedupKey = `${extracted.kind}:${extracted.title}:${extracted.body}`;
                if (!seenNotifs.has(dedupKey)) {
                  seenNotifs.add(dedupKey);
                  if (shouldForward(extracted.kind)) send(extracted);
                }
              }
            }
          }
        }
      }

      // Check raw arrays on the store for notification data
      const dataKeys = ["m_rgNotificationTray", "m_rgNotificationToasts", "m_rgPendingToasts", "m_mapAppOverlayToasts"];
      for (const key of dataKeys) {
        const val = (ns as any)[key];
        if (!val) continue;
        console.log(`[steam-win-notify] ${key}:`, typeof val, val?.size ?? val?.length ?? "");

        let items: any[] = [];
        if (Array.isArray(val)) items = val;
        else if (val instanceof Map) items = [...val.values()];
        else if (typeof val === "object") {
          try { for (const v of Object.values(val)) items.push(v); } catch {}
        }

        for (const item of items) {
          if (!item || typeof item !== "object") continue;
          const extracted = extract(item);
          const tl = (extracted.title + " " + extracted.body).toLowerCase();
          if (tl.includes("controller") || tl.includes("xinput") || tl.includes("gamepad") || tl.includes("xbox")) {
            try { console.log(`[steam-win-notify] *** CONTROLLER NOTIF FOUND in ${key}:`, JSON.stringify(item).slice(0, 2000)); } catch {}
          }
          console.log(`[steam-win-notify]   extracted from ${key}: title="${extracted.title}" body="${extracted.body}" kind="${extracted.kind}"`);
          const dedupKey = `${extracted.kind}:${extracted.title}:${extracted.body}`;
          if (!seenNotifs.has(dedupKey)) {
            seenNotifs.add(dedupKey);
            if (shouldForward(extracted.kind)) send(extracted);
          }
        }
      }
    } catch (e) {
      console.error("[steam-win-notify] forwardPending error:", e);
    }
  }, 8000);
}

function installAllHooks(attempt = 0) {
  const nsOk = patchNotificationStore();
  hookSteamClient();

  if (nsOk) {
    console.log("[steam-win-notify] All hooks installed.");
    forwardPendingNotifications();
    return;
  }
  if (attempt < 60) {
    setTimeout(() => installAllHooks(attempt + 1), 1000);
  } else {
    console.warn(
      "[steam-win-notify] Could not find NotificationStore after 60 attempts."
    );
    forwardPendingNotifications();
  }
}

// Settings UI ---------------------------------------------------------------

function SettingsPanel() {
  const [, setTick] = SP_REACT.useState(0);
  const rerender = () => setTick((t: number) => t + 1);

  const toggle = async () => {
    cfg.enabled = !cfg.enabled;
    await saveConfig();
    rerender();
  };

  return SP_REACT.createElement(
    "div",
    { style: { padding: "16px 24px", maxWidth: 720, overflow: "visible" } },
    SP_REACT.createElement(ToggleField, {
      label: "Enable Windows notifications",
      description: "When off, no Windows toasts will be sent.",
      checked: cfg.enabled,
      onChange: toggle,
    })
  );
}

// Plugin entry ---------------------------------------------------------------

// Check if the browser Notification API is available (sends native Windows
// toasts via Steam's Chromium webhelper process).
function checkNotificationAPI() {
  if (typeof Notification === "undefined") {
    console.warn("[steam-win-notify] Notification API: NOT AVAILABLE");
    return false;
  }
  console.log(
    "[steam-win-notify] Notification API: available, permission=" +
      Notification.permission
  );
  // Auto-request permission if not yet decided.
  if (Notification.permission === "default") {
    Notification.requestPermission().then((perm) => {
      console.log("[steam-win-notify] Notification permission:", perm);
    });
  }
  return true;
}

export default definePlugin(async () => {
  console.log("[steam-win-notify] frontend loading...");
  checkNotificationAPI();
  await loadConfig();
  installAllHooks();

  return {
    title: SP_REACT.createElement("div", null, "Windows Notifications"),
    icon: SP_REACT.createElement(
      "svg",
      {
        width: 16,
        height: 16,
        viewBox: "0 0 24 24",
        fill: "currentColor",
      },
      SP_REACT.createElement("path", {
        d: "M12 2C9.243 2 7 4.243 7 7v3.764L5.553 14H4v2h16v-2h-1.553L17 10.764V7c0-2.757-2.243-5-5-5zm0 19a3 3 0 003-3H9a3 3 0 003 3z",
      })
    ),
    content: SP_REACT.createElement(SettingsPanel),
  };
});
