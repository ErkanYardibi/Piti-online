import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_KEY } from "./config.js";
import {
  escapeHtml as h,
  localDate,
  monthCells,
  packageUsage,
  isOverdue,
  validateRange,
} from "./domain.js";
const db = createClient(SUPABASE_URL, SUPABASE_KEY);
const $ = (s) => document.querySelector(s),
  view = $("#view"),
  modal = $("#modal"),
  back = $("#modalBack");
let user = null,
  profile = null,
  data = {},
  page = "dashboard",
  selected = "",
  showArchived = false,
  cursor = new Date(),
  day = localDate(),
  busy = false,
  generation = 0;
const tables = [
  "clients",
  "packages",
  "sessions",
  "payments",
  "availability",
  "tasks",
  "messages",
];
const isPT = () => profile?.role === "pt";
const money = (n) =>
  new Intl.NumberFormat("tr-TR", {
    style: "currency",
    currency: "TRY",
    maximumFractionDigits: 0,
  }).format(n || 0);
const dateTime = (s) =>
  new Date(s).toLocaleString("tr-TR", {
    dateStyle: "medium",
    timeStyle: "short",
  });
const clientName = (id) =>
  data.clients?.find((c) => c.id === id)?.full_name || "Müşteri";
const selectedClient = () => data.clients?.find((c) => c.id === selected);
const activeClients = () =>
  data.clients.filter((c) => showArchived || !c.archived);
const scoped = (table) =>
  (data[table] || []).filter((r) => !selected || r.client_id === selected);
const label = {
  planned: "Planlı",
  completed: "Tamamlandı",
  no_show: "No Show",
  cancelled: "İptal",
  pending: "Onay bekliyor",
  approved: "Onaylandı",
  rejected: "Reddedildi",
  available: "Müsait",
  unavailable: "Müsait değil",
  leave: "İzinli",
  off: "Çalışmıyor",
  open: "Bekliyor",
  done: "Tamamlandı",
};
const badge = (status) =>
  `<span class="status ${["completed", "approved", "done"].includes(status) ? "green" : status === "pending" ? "amber" : "blue"}">${h(label[status] || status)}</span>`;
const btn = (text, action, cls = "primary", id = "") =>
  `<button class="btn ${cls}" data-action="${action}" data-id="${h(id)}">${text}</button>`;
const field = (name, text, type = "text", value = "", extra = "") =>
  `<div class="field"><label for="f-${name}">${text}</label><input class="input" id="f-${name}" name="${name}" type="${type}" value="${h(value)}" ${extra}></div>`;
const select = (name, text, options, value) =>
  `<div class="field"><label for="f-${name}">${text}</label><select id="f-${name}" name="${name}">${options.map(([v, t]) => `<option value="${h(v)}" ${v === value ? "selected" : ""}>${h(t)}</option>`).join("")}</select></div>`;
const textArea = (name, text, value = "") =>
  `<div class="field"><label for="f-${name}">${text}</label><textarea id="f-${name}" name="${name}" rows="3" maxlength="5000">${h(value)}</textarea></div>`;
const empty = (text) => `<div class="empty">${text}</div>`;
function notify(text) {
  $("#toast").textContent = text;
  $("#toast").classList.add("show");
  clearTimeout(notify.timer);
  notify.timer = setTimeout(() => $("#toast").classList.remove("show"), 4500);
}
function errorText(error) {
  const msg = error?.message || String(error);
  if (/Invalid login credentials/i.test(msg))
    return "E-posta veya şifre hatalı.";
  if (/Email not confirmed/i.test(msg))
    return "Giriş yapmadan önce e-posta adresini doğrula.";
  if (/Failed to fetch|NetworkError/i.test(msg))
    return "Bağlantı kurulamadı. İnternet bağlantını kontrol edip tekrar dene.";
  return msg;
}
async function checked(query) {
  const { data, error } = await query;
  if (error) throw error;
  return data;
}
async function rows(table) {
  let all = [];
  for (let from = 0; ; from += 1000) {
    const chunk = await checked(
      db
        .from(table)
        .select("*")
        .order("id")
        .range(from, from + 999),
    );
    all.push(...chunk);
    if (chunk.length < 1000) return all;
  }
}
async function refresh(render = true) {
  const g = generation;
  const result = await Promise.all(tables.map(rows));
  if (g !== generation) return;
  data = Object.fromEntries(tables.map((t, i) => [t, result[i]]));
  if (selected && !data.clients.some((c) => c.id === selected)) selected = "";
  if (!isPT()) selected = data.clients[0]?.id || "";
  if (render) draw();
}
function toolbar(title, actions = "") {
  return `<div class="toolbar"><div><h1>${title}</h1><div class="statusLine">${isPT() ? "PT hesabı" : "Müşteri hesabı"} · ${h(profile.full_name)}</div></div><div class="rightActions">${actions}</div></div>`;
}
function clientFilter() {
  return isPT()
    ? `<select class="clientSelect" id="clientFilter" aria-label="Müşteri filtresi"><option value="">Tüm müşteriler</option>${activeClients()
        .map(
          (c) =>
            `<option value="${c.id}" ${selected === c.id ? "selected" : ""}>${h(c.full_name)}</option>`,
        )
        .join("")}</select>`
    : "";
}
function authScreen(mode = "login", notice = "") {
  $("#shell").classList.add("auth");
  $("#userbox").innerHTML = "";
  $("#sidebar").innerHTML = "";
  view.innerHTML = `<div class="card authWrap"><h1>${mode === "signup" ? "PiTi’ye katıl" : "PiTi’ye hoş geldin"}</h1><p class="muted">PT ve müşteriler için ortak çalışma alanı.</p><div class="notice">${h(notice)}</div><form id="authForm">${
    mode === "signup"
      ? field("name", "Ad Soyad", "text", "", 'required maxlength="160"') +
        select(
          "role",
          "Hesap türü",
          [
            ["pt", "Personal Trainer (PT)"],
            ["member", "Müşteri"],
          ],
          "pt",
        )
      : ""
  }${field("email", "E-posta", "email", "", 'required autocomplete="email"')}${field("password", "Şifre", "password", "", 'required minlength="8" autocomplete="' + (mode === "signup" ? "new-password" : "current-password") + '"')}<div class="inlineError" id="formError" role="alert"></div><button class="btn primary block">${mode === "signup" ? "Hesap oluştur" : "Giriş yap"}</button></form><div class="actionRow">${btn(mode === "signup" ? "Zaten hesabım var" : "Yeni hesap oluştur", mode === "signup" ? "login" : "signup", "ghost")}</div><p class="small muted">Örnek arayüzü görmek için <a href="demo.html">demoyu aç</a>. Demo kayıtları gerçek hesaba aktarılmaz.</p></div>`;
  $("#authForm").onsubmit = (e) =>
    submit(e, async (f) => {
      if (mode === "signup") {
        const { data: result, error } = await db.auth.signUp({
          email: f.email,
          password: f.password,
          options: { data: { full_name: f.name, preferred_role: f.role } },
        });
        if (error) throw error;
        if (!result.session) {
          authScreen(
            "login",
            "E-postandaki doğrulama bağlantısını açtıktan sonra giriş yapabilirsin.",
          );
          return;
        }
      } else {
        await checked(
          db.auth.signInWithPassword({ email: f.email, password: f.password }),
        );
      }
      await boot();
    });
}
async function submit(event, fn) {
  event.preventDefault();
  if (busy) return;
  busy = true;
  const form = event.currentTarget;
  const buttons = [...form.querySelectorAll("button")];
  buttons.forEach((b) => (b.disabled = true));
  const err = form.querySelector(".inlineError");
  if (err) err.textContent = "";
  try {
    await fn(Object.fromEntries(new FormData(form)));
  } catch (e) {
    if (err && err.isConnected) err.textContent = errorText(e);
    else notify(errorText(e));
  } finally {
    busy = false;
    buttons.forEach((b) => (b.disabled = false));
  }
}
function setupProfile() {
  $("#shell").classList.add("auth");
  view.innerHTML = `<div class="card authWrap"><h1>Profilini tamamla</h1><p class="muted">Hesap türünü bir kez seçersin.</p><form id="profileForm">${field("full_name", "Ad Soyad", "text", user.user_metadata?.full_name || "", 'required maxlength="160"')}${select(
    "role",
    "Hesap türü",
    [
      ["pt", "Personal Trainer (PT)"],
      ["member", "Müşteri"],
    ],
    user.user_metadata?.preferred_role || "pt",
  )}<div class="inlineError" role="alert"></div><button class="btn primary block">Kaydet ve devam et</button></form></div>`;
  $("#profileForm").onsubmit = (e) =>
    submit(e, async (f) => {
      await checked(
        db
          .from("profiles")
          .insert({ id: user.id, full_name: f.full_name.trim(), role: f.role }),
      );
      await boot();
    });
}
async function boot() {
  const g = ++generation;
  const { data: auth, error } = await db.auth.getSession();
  if (error) throw error;
  if (g !== generation) return;
  user = auth.session?.user;
  if (!user) {
    profile = null;
    data = {};
    authScreen();
    return;
  }
  profile = await checked(
    db.from("profiles").select("*").eq("id", user.id).maybeSingle(),
  );
  if (!profile) {
    setupProfile();
    return;
  }
  await refresh();
}
function draw() {
  if (!profile) return;
  $("#shell").classList.remove("auth");
  $("#userbox").innerHTML =
    `<span class="small">${h(profile.full_name)}</span>${btn("Yenile", "refresh", "ghost sm")}${btn("Çıkış", "logout", "ghost sm")}`;
  const navs = [
    ["dashboard", "⌂", "Ana Sayfa"],
    ...(isPT() ? [["clients", "👥", "Müşteriler"]] : []),
    ["calendar", "▣", "Takvim"],
    ["finance", "₺", "Paketler"],
    ["messages", "◌", "Mesajlar"],
  ];
  const unread = data.messages.filter(
    (m) => m.sender_id !== user.id && !m.read_at,
  ).length;
  $("#sidebar").innerHTML = navs
    .map(
      ([p, icon, text]) =>
        `<button class="navBtn ${page === p ? "active" : ""}" data-page="${p}"><span class="navIcon">${icon}</span><span class="navText">${text}${p === "messages" && unread ? " (" + unread + ")" : ""}</span></button>`,
    )
    .join("");
  if (!isPT() && !data.clients.length) {
    view.innerHTML =
      toolbar("PT’ne bağlan") +
      `<div class="card"><p>PT’nden aldığın tek kullanımlık davet kodunu gir.</p><form id="joinForm">${field("token", "Davet kodu", "text", "", "required")}<div class="inlineError" role="alert"></div><button class="btn primary">PT’ye bağlan</button></form></div>`;
    $("#joinForm").onsubmit = (e) =>
      submit(e, async (f) => {
        await checked(db.rpc("accept_invitation", { token: f.token.trim() }));
        await refresh();
      });
    return;
  }
  (({ dashboard, clients, calendar, finance, messages })[page] || dashboard)();
  if ($("#clientFilter"))
    $("#clientFilter").onchange = (e) => {
      selected = e.target.value;
      draw();
    };
}
function sessionCard(s) {
  const overdue = isOverdue(s);
  return `<div class="eventItem ${overdue ? "overdue" : ""}"><div class="eventTop"><div><div class="clientName">${h(clientName(s.client_id))}</div><div>${h(s.workout_title || "PT Seansı")}</div><div class="eventMeta">${dateTime(s.starts_at)}${s.salon ? " · " + h(s.salon) : ""}</div><div class="eventMeta">${h(s.muscle_groups.join(", "))}</div></div>${badge(s.status)}</div>${overdue ? '<div class="notice" style="margin-top:10px">Seansın süresi geçti. PT’nin sonuç girmesi bekleniyor.</div>' : ""}${s.notes ? `<p class="small">${h(s.notes)}</p>` : ""}<div class="actionRow">${isPT() ? `${s.status === "planned" ? btn("Tamamlandı", "complete", "primary sm", s.id) + btn("No Show", "noshow", "amber sm", s.id) : ""}${btn("Düzenle", "edit-session", "ghost sm", s.id)}${s.status === "cancelled" ? btn("Geri al", "restore", "blue sm", s.id) : btn("Seansı sil", "cancel", "red sm", s.id)}` : ""}</div></div>`;
}
function dashboard() {
  const sessions = scoped("sessions")
    .filter((s) => s.status !== "cancelled")
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  const overdue = sessions.filter((s) => isOverdue(s));
  const next = sessions.find(
    (s) => s.status === "planned" && new Date(s.starts_at) >= new Date(),
  );
  const pending = scoped("payments").filter((p) => p.status === "pending");
  view.innerHTML =
    toolbar(
      `Merhaba ${h(profile.full_name.split(" ")[0])} 👋`,
      clientFilter() + (isPT() ? btn("+ Seans planla", "new-session") : ""),
    ) +
    `<div class="grid4">${[
      ["Müşteriler", activeClients().length],
      [
        "Bugünkü seans",
        sessions.filter((s) => localDate(new Date(s.starts_at)) === localDate())
          .length,
      ],
      ["Sonuç bekleyen", overdue.length],
      ["Ödeme onayı", pending.length],
    ]
      .map(
        ([t, n]) =>
          `<div class="card kpi"><div class="kpiLabel">${t}</div><div class="kpiVal">${n}</div></div>`,
      )
      .join(
        "",
      )}</div><div class="grid2" style="margin-top:18px"><div class="card"><h2 class="sectionTitle">Sıradaki seans</h2>${next ? sessionCard(next) : empty("Planlanmış yeni seans yok.")}<h2 class="sectionTitle" style="margin-top:24px">Sonuç bekleyen seanslar</h2>${overdue.map(sessionCard).join("") || empty("Bekleyen sonuç yok.")}</div><div class="card"><div class="toolbar"><h2 class="sectionTitle">Görevler</h2>${isPT() ? btn("+ Görev", "new-task", "ghost sm") : ""}</div>${
      scoped("tasks")
        .map(
          (t) =>
            `<div class="hist"><div><b>${h(t.title)}</b><div class="small muted">${h(clientName(t.client_id))}${t.due_at ? " · " + dateTime(t.due_at) : ""}</div><div class="small">${h(t.result)}</div></div>${t.status === "open" ? btn("Sonuç gir", "task-result", "ghost sm", t.id) : badge(t.status)}</div>`,
        )
        .join("") || empty("Henüz görev yok.")
    }</div></div>`;
}
function clients() {
  view.innerHTML =
    toolbar("Müşteriler", btn("+ Müşteri ekle", "new-client")) +
      `<label><input id="archiveToggle" type="checkbox" ${showArchived ? "checked" : ""}> Arşivlenmiş müşterileri göster</label>` +
      activeClients()
        .map(
          (c) =>
            `<div class="card" style="margin-top:12px"><div class="clientName">${h(c.full_name)} ${c.archived ? badge("Arşiv") : ""}</div><p class="small muted">${h(c.email)} · ${h(c.phone)}</p><div class="small">${c.user_id ? "✓ Müşteri hesabı bağlı" : `Davet kodu: <code>${h(c.invite_token)}</code>`}</div><div class="actionRow">${btn("Takvim", "client-calendar", "primary sm", c.id)}${btn("Paketler", "client-finance", "ghost sm", c.id)}${btn("Mesaj", "client-messages", "ghost sm", c.id)}${btn(c.archived ? "Arşivden çıkar" : "Arşivle", "archive", "ghost sm", c.id)}</div></div>`,
        )
        .join("") || empty("Henüz müşteri yok.");
  $("#archiveToggle").onchange = (e) => {
    showArchived = e.target.checked;
    clients();
  };
}
function clientOptions() {
  return activeClients().map((c) => [c.id, c.full_name]);
}
function clientForm() {
  openForm(
    "Müşteri ekle",
    field("full_name", "Ad Soyad", "text", "", 'required maxlength="160"') +
      field("email", "E-posta", "email", "", "required") +
      field("phone", "Telefon", "tel", "", "required") +
      select("blood_type", "Kan grubu", [
        ["unknown", "Bilinmiyor"],
        ...["A+", "A-", "B+", "B-", "AB+", "AB-", "0+", "0-"].map((x) => [
          x,
          x,
        ]),
      ]) +
      select("gender", "Cinsiyet", [
        ["female", "Kadın"],
        ["male", "Erkek"],
        ["unspecified", "Belirtmek istemiyorum"],
      ]) +
      field(
        "weight",
        "Kilo (kg)",
        "number",
        "",
        'required min="1" max="500" step="0.1"',
      ) +
      field("height", "Boy (cm)", "number", "", 'required min="30" max="280"'),
    async (f) => {
      await checked(
        db
          .from("clients")
          .insert({
            ...f,
            weight: +f.weight,
            height: +f.height,
            pt_id: user.id,
          }),
      );
    },
  );
}
function calendar() {
  const sessions = scoped("sessions");
  const availability = data.availability.filter(
    (a) => !selected || a.client_id === selected || !a.client_id,
  );
  const selectedRows = sessions
    .filter((s) => localDate(new Date(s.starts_at)) === day)
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  view.innerHTML =
    toolbar(
      "Takvim",
      clientFilter() +
        btn(
          isPT() ? "+ Müsaitlik / izin" : "+ Müsait değilim",
          "new-availability",
          "ghost",
        ) +
        (isPT() ? btn("+ Seans", "new-session") : ""),
    ) +
    `<div class="calendarWrap"><div class="calendar"><div class="calHead">${btn("‹", "prev-month", "ghost")}<div class="calTitle">${cursor.toLocaleDateString("tr-TR", { month: "long", year: "numeric" })}</div>${btn("Bugün", "today", "ghost")}${btn("›", "next-month", "ghost")}</div><div class="week">${["Pzt", "Sal", "Çar", "Per", "Cum", "Cmt", "Paz"].map((x) => `<div>${x}</div>`).join("")}</div><div class="days">${monthCells(
      cursor,
    )
      .map((d) => {
        const ds = localDate(d),
          count = sessions.filter(
            (s) =>
              localDate(new Date(s.starts_at)) === ds &&
              s.status !== "cancelled",
          ).length;
        return `<button class="day ${ds === day ? "selected" : ""} ${ds === localDate() ? "today" : ""} ${d.getMonth() !== cursor.getMonth() ? "dim" : ""}" data-day="${ds}"><span class="dayNum">${d.getDate()}</span>${count ? `<span class="dayBadge blue">${count} seans</span><div class="dotRow"><span class="dot blue"></span></div>` : ""}</button>`;
      })
      .join(
        "",
      )}</div></div><div class="card"><h2 class="sectionTitle">${new Date(day + "T12:00:00").toLocaleDateString("tr-TR", { dateStyle: "long" })}</h2>${selectedRows.map(sessionCard).join("") || empty("Bu gün için seans yok.")}${availability
      .filter(
        (a) =>
          localDate(new Date(a.starts_at)) <= day &&
          localDate(new Date(a.ends_at || a.starts_at)) >= day,
      )
      .sort((a, b) => a.starts_at.localeCompare(b.starts_at))
      .map(
        (a) =>
          `<div class="eventItem"><b>${a.client_id ? h(clientName(a.client_id)) : "PT"} · ${h(label[a.kind])}</b><div class="eventMeta">${a.all_day ? "Tüm gün" : dateTime(a.starts_at) + " – " + dateTime(a.ends_at)}</div><p>${h(a.note)}</p>${(!a.client_id && a.pt_id === user.id) || (a.client_id && data.clients.find((c) => c.id === a.client_id)?.user_id === user.id) ? btn("Sil", "delete-availability", "red sm", a.id) : ""}</div>`,
      )
      .join("")}</div></div>`;
}
function localInput(value) {
  const d = new Date(value);
  return `${localDate(d)}T${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}
function sessionForm(id) {
  if (!activeClients().length) {
    notify("Önce bir müşteri ekle.");
    return;
  }
  const s = data.sessions.find((s) => s.id === id),
    start = s ? localInput(s.starts_at) : day + "T18:00",
    end = s
      ? localInput(
          s.ends_at || new Date(new Date(s.starts_at).getTime() + 3600000),
        )
      : day + "T19:00";
  openForm(
    s ? "Seansı düzenle" : "Seans planla",
    select("client_id", "Müşteri", clientOptions(), s?.client_id || selected) +
      field("starts_at", "Başlangıç", "datetime-local", start, "required") +
      field("ends_at", "Bitiş", "datetime-local", end, "required") +
      field(
        "workout_title",
        "Antrenman",
        "text",
        s?.workout_title || "PT Seansı",
        'required maxlength="160"',
      ) +
      field(
        "muscle_groups",
        "Kas grupları (virgülle ayır)",
        "text",
        s?.muscle_groups.join(", ") || "",
      ) +
      field("salon", "Salon", "text", s?.salon || "") +
      textArea("notes", "Not", s?.notes || "") +
      select(
        "status",
        "Durum",
        Object.entries(label).filter(([k]) =>
          ["planned", "completed", "no_show", "cancelled"].includes(k),
        ),
        s?.status || "planned",
      ) +
      select(
        "counts_against_package",
        "Paketten düşülsün mü?",
        [
          ["true", "Evet"],
          ["false", "Hayır / Ücretsiz demo"],
        ],
        String(s?.counts_against_package ?? true),
      ),
    async (f) => {
      validateRange(f.starts_at, f.ends_at);
      const row = {
        ...f,
        pt_id: user.id,
        starts_at: new Date(f.starts_at).toISOString(),
        ends_at: new Date(f.ends_at).toISOString(),
        muscle_groups: f.muscle_groups
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean),
        counts_against_package: f.counts_against_package === "true",
      };
      await checked(
        s
          ? db.from("sessions").update(row).eq("id", id).select().single()
          : db.from("sessions").insert(row),
      );
    },
  );
  $("#f-starts_at").onchange = (e) => {
    $("#f-ends_at").value = localInput(
      new Date(new Date(e.target.value).getTime() + 3600000),
    );
  };
}
function availabilityForm() {
  openForm(
    isPT() ? "Müsaitlik / izin ekle" : "Müsait değilim",
    field(
      "starts_at",
      "Başlangıç",
      "datetime-local",
      day + "T18:00",
      "required",
    ) +
      field("ends_at", "Bitiş", "datetime-local", day + "T19:00", "required") +
      select(
        "all_day",
        "Süre",
        [
          ["false", "Saat aralığı"],
          ["true", "Tüm gün"],
        ],
        "false",
      ) +
      (isPT()
        ? select("kind", "Durum", [
            ["available", "Müsait"],
            ["leave", "İzinli"],
            ["off", "Çalışmıyor"],
          ])
        : "") +
      textArea("note", "Not / PT’ye mesaj"),
    async (f) => {
      if (f.all_day === "true") {
        f.starts_at = f.starts_at.slice(0, 10) + "T00:00";
        f.ends_at = f.ends_at.slice(0, 10) + "T23:59";
      }
      validateRange(f.starts_at, f.ends_at);
      await checked(
        db
          .from("availability")
          .insert({
            ...f,
            starts_at: new Date(f.starts_at).toISOString(),
            ends_at: new Date(f.ends_at).toISOString(),
            all_day: f.all_day === "true",
            kind: isPT() ? f.kind : "unavailable",
            pt_id: isPT() ? user.id : null,
            client_id: isPT() ? null : selected,
          }),
      );
    },
  );
  $("#f-starts_at").onchange = (e) => {
    $("#f-ends_at").value = localInput(
      new Date(new Date(e.target.value).getTime() + 3600000),
    );
  };
}
function finance() {
  view.innerHTML =
    toolbar(
      isPT() ? "Paketler ve ödemeler" : "Paketim ve ödemelerim",
      clientFilter() +
        (isPT() ? btn("+ Paket", "new-package") : "") +
        btn("Ödeme bildir", "new-payment", "ghost"),
    ) +
    `<div class="grid2"><div class="card"><h2 class="sectionTitle">Paketler</h2>${
      scoped("packages")
        .sort((a, b) => b.created_at.localeCompare(a.created_at))
        .map((p) => {
          const used = packageUsage(p, data.sessions),
            left = Math.max(0, p.total_sessions - used);
          return `<div class="eventItem"><div class="clientName">${h(clientName(p.client_id))}</div><b>${h(p.name)}</b><p>${money(p.price)} · ${left}/${p.total_sessions} seans kaldı</p><p class="small muted">${h(p.start_date)} – ${h(p.expiry_date)} · Süre veya seans, hangisi önce biterse</p>${badge(p.expiry_date < localDate() || left === 0 ? "Bitti" : "Aktif")}</div>`;
        })
        .join("") || empty("Henüz paket yok.")
    }</div><div class="card"><h2 class="sectionTitle">Ödeme geçmişi</h2>${
      scoped("payments")
        .sort((a, b) => b.created_at.localeCompare(a.created_at))
        .map(
          (p) =>
            `<div class="eventItem"><b>${h(clientName(p.client_id))} · ${money(p.amount)}</b><p class="small">${h(p.method)} · ${dateTime(p.created_at)}</p>${badge(p.status)}${isPT() && p.status === "pending" ? `<div class="actionRow">${btn("Onayla", "approve-payment", "primary sm", p.id)}${btn("Reddet", "reject-payment", "red sm", p.id)}</div>` : ""}</div>`,
        )
        .join("") || empty("Henüz ödeme yok.")
    }</div></div>`;
}
function packageForm() {
  if (!activeClients().length) return notify("Önce müşteri ekle.");
  const end = new Date();
  end.setDate(end.getDate() + 30);
  openForm(
    "Yeni paket",
    select("client_id", "Müşteri", clientOptions(), selected) +
      field("name", "Paket adı", "text", "12 Seans / 30 Gün", "required") +
      field(
        "price",
        "Tutar (₺)",
        "number",
        "7500",
        'required min="0" step="0.01"',
      ) +
      field(
        "total_sessions",
        "Seans sayısı",
        "number",
        "12",
        'required min="1"',
      ) +
      field("start_date", "Başlangıç", "date", localDate(), "required") +
      field("expiry_date", "Bitiş", "date", localDate(end), "required"),
    async (f) => {
      if (f.expiry_date < f.start_date)
        throw new Error("Bitiş başlangıçtan önce olamaz.");
      await checked(
        db
          .from("packages")
          .insert({ ...f, price: +f.price, total_sessions: +f.total_sessions }),
      );
    },
  );
}
function paymentForm() {
  if (!activeClients().length) return notify("Önce müşteri ekle.");
  openForm(
    "Ödeme bildirimi",
    select("client_id", "Müşteri", clientOptions(), selected) +
      field(
        "amount",
        "Ödenen tutar (₺)",
        "number",
        "",
        'required min="0.01" step="0.01"',
      ) +
      select("method", "Yöntem", [
        ["EFT/Havale", "EFT/Havale"],
        ["Nakit", "Nakit"],
        ["Diğer", "Diğer"],
      ]) +
      '<div class="notice">Bildirim PT onayına gönderilir. Bu sürümde dekont dosyası yüklenmez.</div>',
    async (f) => {
      await checked(
        db
          .from("payments")
          .insert({
            ...f,
            amount: +f.amount,
            status: "pending",
            paid_at: new Date().toISOString(),
          }),
      );
    },
  );
}
function taskForm() {
  if (!activeClients().length) return notify("Önce müşteri ekle.");
  openForm(
    "Görev gönder",
    select("client_id", "Müşteri", clientOptions(), selected) +
      field("title", "Görev", "text", "", 'required maxlength="300"') +
      field(
        "due_at",
        "Son tarih",
        "datetime-local",
        day + "T21:00",
        "required",
      ),
    async (f) => {
      await checked(
        db
          .from("tasks")
          .insert({
            ...f,
            pt_id: user.id,
            due_at: new Date(f.due_at).toISOString(),
          }),
      );
    },
  );
}
function messages() {
  if (!selected) {
    view.innerHTML =
      toolbar("Mesajlar", clientFilter()) +
      empty("Görüşmeyi açmak için bir müşteri seç.");
    return;
  }
  const msgs = scoped("messages").sort((a, b) =>
    a.created_at.localeCompare(b.created_at),
  );
  view.innerHTML =
    toolbar("Mesajlar", clientFilter()) +
    `<div class="card"><div class="subTitle">${isPT() ? h(clientName(selected)) : "PT ile görüşme"}</div><div class="chat" id="chatBox">${msgs.map((m) => `<div class="msg ${m.sender_id === user.id ? "me" : "them"}">${h(m.body)}<div class="small muted">${dateTime(m.created_at)}${m.sender_id === user.id && m.read_at ? " · Okundu" : ""}</div></div>`).join("") || empty("İlk mesajını gönder.")}</div><form id="messageForm"><div class="composer"><input class="input" name="body" placeholder="Mesaj yaz…" aria-label="Mesaj" required maxlength="5000"><button class="btn primary">Gönder</button></div><div class="inlineError" role="alert"></div></form></div>`;
  $("#chatBox").scrollTop = $("#chatBox").scrollHeight;
  $("#messageForm").onsubmit = (e) =>
    submit(e, async (f) => {
      if (!f.body.trim()) throw new Error("Mesaj boş olamaz.");
      await checked(
        db
          .from("messages")
          .insert({
            client_id: selected,
            sender_id: user.id,
            body: f.body.trim(),
          }),
      );
      await refresh();
    });
  const unread = msgs.filter((m) => m.sender_id !== user.id && !m.read_at);
  if (unread.length)
    db.from("messages")
      .update({ read_at: new Date().toISOString() })
      .in(
        "id",
        unread.map((m) => m.id),
      )
      .then(({ error }) => {
        if (error) notify("Okundu bilgisi kaydedilemedi.");
      });
}
function openForm(title, fields, onSave) {
  modal.innerHTML = `<h3>${title}</h3><form id="editForm">${fields}<div class="inlineError" role="alert"></div><div class="modalFoot"><button type="button" class="btn ghost" data-action="close">Vazgeç</button><button class="btn primary">Kaydet</button></div></form>`;
  back.classList.add("show");
  $("#editForm").onsubmit = (e) =>
    submit(e, async (f) => {
      await onSave(f);
      back.classList.remove("show");
      await refresh();
      notify("Kaydedildi.");
    });
}
async function updateRow(table, id, values) {
  await checked(
    db.from(table).update(values).eq("id", id).select("id").single(),
  );
  await refresh();
  notify("Kaydedildi.");
}
const actions = {
  login: () => authScreen(),
  signup: () => authScreen("signup"),
  close: () => back.classList.remove("show"),
  refresh: () => refresh(),
  logout: async () => {
    await checked(db.auth.signOut());
    generation++;
    user = null;
    profile = null;
    data = {};
    selected = "";
    page = "dashboard";
    authScreen();
  },
  "new-client": clientForm,
  "new-session": () => sessionForm(),
  "edit-session": sessionForm,
  "new-availability": availabilityForm,
  "new-package": packageForm,
  "new-payment": paymentForm,
  "new-task": taskForm,
  "prev-month": () => {
    cursor = new Date(cursor.getFullYear(), cursor.getMonth() - 1, 1);
    draw();
  },
  "next-month": () => {
    cursor = new Date(cursor.getFullYear(), cursor.getMonth() + 1, 1);
    draw();
  },
  today: () => {
    cursor = new Date();
    day = localDate();
    draw();
  },
  complete: (id) => updateRow("sessions", id, { status: "completed" }),
  noshow: (id) =>
    openForm(
      "No Show",
      select("counts", "Paketten düşülsün mü?", [
        ["true", "Evet"],
        ["false", "Hayır"],
      ]) +
        textArea(
          "notes",
          "Mazeret / not",
          data.sessions.find((s) => s.id === id).notes || "",
        ),
      (f) =>
        checked(
          db
            .from("sessions")
            .update({
              status: "no_show",
              counts_against_package: f.counts === "true",
              notes: f.notes,
            })
            .eq("id", id)
            .select("id")
            .single(),
        ),
    ),
  cancel: async (id) => {
    if (
      confirm(
        "Bu seansı silmek istiyor musun? İptal olarak saklanır ve geri alınabilir.",
      )
    )
      await updateRow("sessions", id, {
        status: "cancelled",
        cancelled_from_status: data.sessions.find((s) => s.id === id).status,
      });
  },
  restore: (id) =>
    updateRow("sessions", id, {
      status:
        data.sessions.find((s) => s.id === id).cancelled_from_status ||
        "planned",
      cancelled_from_status: null,
    }),
  archive: (id) =>
    updateRow("clients", id, {
      archived: !data.clients.find((c) => c.id === id).archived,
    }),
  "delete-availability": async (id) => {
    if (confirm("Bu takvim kaydı silinsin mi?")) {
      await checked(
        db.from("availability").delete().eq("id", id).select("id").single(),
      );
      await refresh();
    }
  },
  "approve-payment": (id) => updateRow("payments", id, { status: "approved" }),
  "reject-payment": (id) => updateRow("payments", id, { status: "rejected" }),
  "task-result": (id) =>
    openForm("Görev sonucu", textArea("result", "Sonuç"), (f) =>
      checked(
        db
          .from("tasks")
          .update({ status: "done", result: f.result })
          .eq("id", id)
          .select("id")
          .single(),
      ),
    ),
  "client-calendar": (id) => {
    selected = id;
    page = "calendar";
    draw();
  },
  "client-finance": (id) => {
    selected = id;
    page = "finance";
    draw();
  },
  "client-messages": (id) => {
    selected = id;
    page = "messages";
    draw();
  },
};
document.addEventListener("click", async (e) => {
  const el = e.target.closest("[data-action],[data-page],[data-day]");
  if (!el || busy) return;
  if (el.dataset.page) {
    page = el.dataset.page;
    draw();
    return;
  }
  if (el.dataset.day) {
    day = el.dataset.day;
    draw();
    return;
  }
  const action = actions[el.dataset.action];
  if (!action) return;
  el.disabled = true;
  try {
    await action(el.dataset.id);
  } catch (error) {
    notify(errorText(error));
  } finally {
    el.disabled = false;
  }
});
back.addEventListener("click", (e) => {
  if (e.target === back && !busy) back.classList.remove("show");
});
db.auth.onAuthStateChange((event) => {
  if (event === "SIGNED_OUT") {
    generation++;
    user = null;
    profile = null;
    data = {};
    authScreen();
  }
});
setInterval(() => {
  if (
    profile &&
    !busy &&
    !document.hidden &&
    !back.classList.contains("show") &&
    !["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement?.tagName)
  )
    refresh().catch(() =>
      notify("Veriler yenilenemedi. Yenile düğmesiyle tekrar dene."),
    );
}, 20000);
boot().catch((error) => authScreen("login", errorText(error)));
