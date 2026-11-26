"use strict";

const app = document.querySelector("#app");
const notice = document.querySelector("#notice");
const state = { me: null, page: "matches", category: 0, questions: [], chat: null, auth: "register", authEmail: "" };
const genders = ["woman", "man", "nonbinary", "other"];
const intentions = ["serious", "casual", "exploring", "other"];
const lifestyleKeys = ["smoking", "drinking", "children"];
const labels = { serious: "Long-term relationship", casual: "Casual dating", exploring: "Exploring", other: "Other", nonbinary: "Nonbinary", woman: "Woman", man: "Man" };
const scale = [[5, "Strongly agree"], [4, "Agree"], [3, "Neutral"], [2, "Disagree"], [1, "Strongly disagree"]];
const esc = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const label = value => labels[value] || value;
const icons = {
  matches: '<circle cx="8" cy="12" r="4.5"/><circle cx="16" cy="12" r="4.5"/>',
  questionnaire: '<path d="M5 4.5h14v15H5z"/><path d="M8 9h8M8 13h8M8 17h5"/>',
  messages: '<path d="M4.5 5.5h15v11h-9l-4 3v-3h-2z"/>',
  profile: '<circle cx="12" cy="8" r="3.5"/><path d="M5 19c.4-3.4 3-5.5 7-5.5s6.6 2.1 7 5.5"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.5 1.5M16.5 16.5 18 18M18 6l-1.5 1.5M7.5 16.5 6 18"/>',
};
const navIcon = name => `<svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name]}</svg>`;

async function api(path, options = {}) {
  const headers = { "X-Pair-Request": "1", ...(options.headers || {}) };
  if (options.body && !(options.body instanceof FormData)) {
    headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(options.body);
  }
  const response = await fetch(`/api/v1${path}`, { ...options, headers, credentials: "same-origin" });
  const result = await response.json();
  if (!response.ok) {
    const error = new Error(result.error || "Something went wrong.");
    error.status = response.status;
    throw error;
  }
  return result;
}

function toast(message, error = false) {
  notice.className = `notice${error ? " error" : ""}`;
  notice.setAttribute("role", error ? "alert" : "status");
  notice.textContent = message;
  clearTimeout(toast.timer);
  if (error) {
    const dismiss = document.createElement("button");
    dismiss.type = "button";
    dismiss.dataset.action = "dismiss-notice";
    dismiss.className = "notice-dismiss";
    dismiss.textContent = "Dismiss";
    notice.append(" ", dismiss);
  }
  if (!error) toast.timer = setTimeout(() => { notice.className = ""; notice.textContent = ""; }, 5000);
}

async function refresh() {
  state.me = await api("/me");
}

function field(name, title, value = "", type = "text", extra = "") {
  return `<div class="field"><label for="${name}">${title}</label><input id="${name}" name="${name}" type="${type}" value="${esc(value)}" ${extra}></div>`;
}
function select(name, title, options, value) {
  return `<div class="field"><label for="${name}">${title}</label><select id="${name}" name="${name}" required><option value="">Select one</option>${options.map(o => `<option value="${esc(o)}" ${o === value ? "selected" : ""}>${esc(label(o))}</option>`).join("")}</select></div>`;
}
function checks(name, options, selected = []) {
  return `<div class="checks">${options.map(o => `<label class="check"><input type="checkbox" name="${name}" value="${esc(o)}" ${selected.includes(o) ? "checked" : ""}>${esc(label(o))}</label>`).join("")}</div>`;
}

function shell(content) {
  const pages = [["matches", "Matches"], ["questionnaire", "Your answers"], ["messages", "Messages"], ["profile", "Profile"], ["settings", "Settings"]];
  const name = state.me.profile?.name || "you";
  app.innerHTML = `<div class="shell">
    <aside class="sidebar"><a class="brand" href="/">pair<span>.</span></a><nav class="nav" aria-label="Main navigation">
    ${pages.map(([id, title]) => `<button type="button" data-page="${id}" class="${state.page === id ? "active" : ""}" ${state.page === id ? 'aria-current="page"' : ""}>${navIcon(id)}<span>${title}</span></button>`).join("")}
    </nav><div class="sidebar-footer">Up to three introductions each week.</div></aside>
    <div class="main"><header class="topbar"><div><strong>${state.me.profile ? `Welcome, ${esc(name)}` : "Welcome to PAIR"}</strong><p>Weekly introductions based on mutual preferences.</p></div><div class="avatar" aria-hidden="true">${esc(name[0].toUpperCase())}</div></header>
    <main id="content" class="content" tabindex="-1">${content}</main></div></div>`;
}

function authPage() {
  const register = state.auth === "register";
  const activate = state.auth === "activate";
  app.innerHTML = `<div class="auth"><section class="hero"><a class="brand" href="/">pair<span>.</span></a><div class="hero-content"><h1>Dating without the endless scroll<span>.</span></h1><p class="hero-copy">Get up to three introductions each week, based on your preferences and compatibility answers.</p><div class="hero-facts" aria-label="How PAIR works"><div><strong>64</strong><span>questions about what matters to you</span></div><div><strong>Both</strong><span>people’s preferences come first</span></div><div><strong>3</strong><span>introductions at most, once a week</span></div></div></div><p class="hero-bottom">For adults looking for all kinds of connection.</p></section>
  <main id="content" class="auth-side" tabindex="-1"><div class="auth-box"><h2>${register ? "Create your account" : activate ? "Complete registration" : "Sign in"}</h2><p class="subtitle">${register ? "Start by entering your email address." : activate ? "If registration is available, check your email for a code. Otherwise, sign in." : "Sign in to see your profile and introductions."}</p>
  <form id="auth-form">${activate ? field("code", "Registration code", "", "text", "required autocomplete=\"one-time-code\"") : field("email", "Email address", state.authEmail, "email", "required autocomplete=\"email\"")}
  ${!register ? field("password", "Password", "", "password", `required minlength="${activate ? 12 : 1}" autocomplete="${activate ? "new-password" : "current-password"}"`) : ""}
  ${activate ? '<p class="hint">Use at least 12 characters for your password.</p>' : ""}
  ${activate ? '<label class="checkbox-line"><input name="adult" type="checkbox" required> I confirm I am 18 or older and agree to treat others with respect.</label>' : ""}
  <button class="btn" type="submit">${register ? "Continue" : activate ? "Create your account" : "Sign in"}</button></form>
  <button type="button" class="link-button" data-action="toggle-auth">${state.auth !== "login" ? "Already have an account? Sign in" : "New here? Create an account"}</button>
  ${activate ? '<button type="button" class="link-button" data-action="restart-registration">Use a different email</button>' : ""}
  <p class="hint">Local prototype: do not use real personal data.</p></div></main></div>`;
}

function onboarding() {
  const me = state.me;
  const items = [
    ["Account verification", me.verified, "settings"],
    ["Your profile", !!me.profile, "profile"],
    [me.photo === "pending" ? "Photo awaiting review" : "Approved photo", me.photo === "approved", "profile"],
    ["Dating preferences", !!me.preferences, "preferences"],
    [`Compatibility questions (${Object.keys(me.answers).length}/64)`, Object.keys(me.answers).length === 64, "questionnaire"],
  ];
  const completed = items.filter(x => x[1]).length;
  return `<div class="heading-row"><div><h1>Complete your profile</h1><p class="subtitle">Finish these steps to be considered for weekly introductions.</p></div><span class="pill">${completed} of 5 complete</span></div>
  <div class="intro"><div><strong>Matching starts after onboarding</strong><p>Complete every step before the next weekly cycle.</p></div></div>
  <div class="grid-two"><div class="panel"><h2>Your checklist</h2><p>Your answers stay private. You can update them anytime.</p><div class="progress" role="progressbar" aria-label="Onboarding progress" aria-valuemin="0" aria-valuemax="5" aria-valuenow="${completed}"><span style="width:${completed * 20}%"></span></div><div class="step-list">${items.map(([title, done, page]) => `<div class="step"><div><strong>${esc(title)}</strong><br><small>${done ? "Complete" : title === "Photo awaiting review" ? "Awaiting review" : "Not complete"}</small></div><button class="btn ${done ? "soft" : "secondary"}" data-page="${page}" aria-label="${done ? "View" : "Continue"}: ${esc(title)}">${done ? "View" : "Continue"}</button></div>`).join("")}</div></div>
  <div class="panel"><h2>Introductions once a week</h2><p>Every Monday, you may receive up to three introductions based on mutual preferences and compatibility.</p><p>Compatibility is an estimate, not a guarantee of relationship success. Take your time and respect each other's boundaries.</p></div></div>`;
}

async function matchesPage() {
  if (!state.me.ready) return onboarding();
  const data = await api("/matches");
  return `<div class="heading-row"><div><h1>Your introductions</h1><p class="subtitle">Up to three people who meet your mutual preferences.</p></div><span class="pill">Updated weekly</span></div>
  ${state.me.matching_paused ? '<div class="intro"><div><strong>Your profile is paused</strong><p>Introductions and conversations are hidden until you resume in Settings.</p></div></div>' : ""}
  <div class="intro"><div><strong>Take your time</strong><p>You can message someone after you both choose Like.</p></div></div>
  <div class="section-head"><h2>People to get to know</h2><span>${data.matches.length} introduction${data.matches.length === 1 ? "" : "s"} ${data.cycle ? "this week" : ""}</span></div>
  ${data.matches.length ? `<div class="cards">${data.matches.map(matchCard).join("")}</div>` : `<div class="empty"><h3>${data.cycle ? "No introductions this week" : "No introductions yet"}</h3><p>${data.cycle ? "There are no available introductions for you this week. We don't add replacements midweek." : "The first matching cycle hasn't run yet. Introductions are selected on Mondays."}</p></div>`}
  ${data.invitations.length ? `<div class="section-head"><h2>Private invitations</h2><span>These people liked you this week.</span></div><p class="hint">Invitations are separate from your three weekly introductions and expire with this cycle.</p><div class="cards">${data.invitations.map(matchCard).join("")}</div>` : ""}
  <p class="hint">Compatibility is an estimate, not a guarantee of relationship success. ${data.cycle ? `Cycle: ${esc(new Date(data.cycle.id).toLocaleString())}.` : ""}</p>`;
}

function matchCard(m) {
  const bars = Object.entries(m.breakdown).map(([name, value]) => `<div class="bar-row"><span>${esc(name)}</span><span class="bar"><i style="width:${value}%"></i></span><b>${Math.round(value)}%</b></div>`).join("");
  return `<article class="card"><img class="photo" src="/api/v1/photo/${m.id}" alt="${esc(m.name)}'s approved profile photo"><div class="card-body">
  <div class="card-title"><h3>${esc(m.name)}, ${m.age}</h3><span class="score">${Math.round(m.score)}% <span>compatible</span></span></div>
  <p class="meta">${esc(m.distance_label)} &nbsp;·&nbsp; ${esc(label(m.intention))}</p>
  <div>${m.shared_interests.length ? `<span class="hint">Shared interests: </span>${m.shared_interests.map(i => `<span class="tag">${esc(i)}</span>`).join("")}` : '<span class="hint">No shared interests listed</span>'}</div>
  <p class="card-copy">${esc(m.bio)}</p><p class="card-copy">${m.similarities.length ? `You answered similarly in ${esc(m.similarities.join(" and ").toLowerCase())}.` : "You can explore what makes your perspectives different."}</p>
  <details class="details"><summary>See compatibility breakdown</summary>${bars}<p class="hint">An estimate based on your responses; individual answers are private.</p></details>
  <div class="card-actions"><button class="btn secondary" data-action="pass" data-id="${m.id}" aria-label="Pass on ${esc(m.name)}">Pass</button><button class="btn" data-action="like" data-id="${m.id}" aria-label="${m.reaction === "like" ? "Liked" : "Like"} ${esc(m.name)}" ${m.reaction === "like" ? "disabled" : ""}>${m.reaction === "like" ? "Liked" : "Like"}</button></div>
  <div class="card-actions"><button class="link-button" data-action="report" data-id="${m.id}" aria-label="Report ${esc(m.name)}">Report</button><button class="link-button" data-action="block" data-id="${m.id}" aria-label="Block ${esc(m.name)}">Block</button></div></div></article>`;
}

function profilePage() {
  const p = state.me.profile || {};
  const life = p.lifestyle || {};
  return `<div class="heading-row"><div><h1>Your profile</h1><p class="subtitle">Tell potential matches about yourself.</p></div></div>
  <div class="grid-two" style="margin-top:25px"><section class="panel"><h2>About you</h2><form id="profile-form">
  <div class="form-grid">${field("name", "First name", p.name, "text", "required maxlength=\"40\"")}${field("birth_date", "Date of birth", p.birth_date, "date", "required")}</div>
  ${field("city", "General location", p.city, "text", "required maxlength=\"80\"")}<p class="hint">Use a city or general area, never a street address. Your exact coordinates are never shared.</p>
  <div class="form-grid">${field("latitude", "Latitude", p.latitude, "number", "required step=\"any\" min=\"-90\" max=\"90\"")}${field("longitude", "Longitude", p.longitude, "number", "required step=\"any\" min=\"-180\" max=\"180\"")}</div><p class="hint">Coordinates are used only for your distance preference. For this prototype, enter your approximate city coordinates manually.</p>
  <div class="field"><label for="bio">A little about you</label><textarea id="bio" name="bio" required minlength="10" maxlength="600">${esc(p.bio || "")}</textarea></div><p class="hint">Your bio is visible to introductions. Don't include your address or other sensitive information.</p>
  <div class="form-grid">${select("gender", "Gender", genders, p.gender)}${select("intention", "Dating intention", intentions, p.intention)}</div>
  ${field("interests", "Interests (comma-separated)", (p.interests || []).join(", "), "text", "required")}
  ${lifestyleKeys.map(k => field(k, `${k[0].toUpperCase() + k.slice(1)} — your preference`, life[k], "text", "required maxlength=\"40\"")).join("")}
  <p class="hint">Use simple terms such as “no”, “yes”, or “sometimes”; dealbreakers compare these values exactly.</p>
  <div class="form-actions"><button class="btn">Save profile</button><button type="button" class="btn secondary" data-page="preferences">Edit preferences</button></div></form></section>
  <div><section class="panel"><h2>Your photo</h2><p>One clear photo is required. Images are reviewed before they can appear in introductions. Status: <strong>${esc(state.me.photo)}</strong>.</p>
  ${state.me.photo !== "missing" ? `<img class="photo" style="border-radius:12px;max-height:250px" src="/api/v1/photo/${state.me.id}" alt="Your submitted photo">` : ""}
  <form id="photo-form"><div class="field"><label for="photo">Choose a JPEG or PNG</label><input id="photo" type="file" name="photo" accept="image/jpeg,image/png" required></div><button class="btn secondary">Submit for review</button></form></section>
  <section class="panel"><h2>Your preferences</h2><p>Tell us what works for you. Matching only happens when your preferences work both ways.</p><button class="btn soft" data-page="preferences">Set preferences →</button></section></div></div>`;
}

function preferencesPage() {
  const p = state.me.preferences || {};
  return `<div class="heading-row"><div><h1>Your preferences</h1><p class="subtitle">You'll only see people who meet your preferences, and whose preferences you meet too.</p></div></div>
  <section class="panel" style="margin-top:25px;max-width:760px"><form id="preferences-form"><h2>What you're looking for</h2>
  <div class="form-grid">${field("min_age", "Minimum age", p.min_age ?? 18, "number", "required min=\"18\" max=\"120\"")}${field("max_age", "Maximum age", p.max_age ?? 99, "number", "required min=\"18\" max=\"120\"")}</div>
  ${field("distance", "Maximum distance (km)", p.distance ?? 50, "number", "required min=\"1\" max=\"20000\"")}<p class="hint">For privacy, distance checks include a safety margin. Smaller limits may yield no matches.</p>
  <fieldset><legend>Genders you want to date</legend>${checks("genders", genders, p.genders)}</fieldset>
  <fieldset><legend>Dating intentions you're open to</legend>${checks("intentions", intentions, p.intentions)}</fieldset>
  <h2>Dealbreakers</h2><p>Optional. If set, a potential match's lifestyle answer must match exactly. Leave blank for no restriction.</p>
  ${lifestyleKeys.map(k => field(`deal_${k}`, `Required ${k} answer`, p.dealbreakers?.[k] || "", "text", "maxlength=\"40\"")).join("")}
  <button class="btn">Save preferences</button></form></section>`;
}

async function questionnairePage() {
  if (!state.questions.length) state.questions = await api("/questions");
  const categories = [...new Set(state.questions.map(q => q.category))];
  const questions = state.questions.filter(q => q.category === categories[state.category]);
  const count = Object.keys(state.me.answers).length;
  return `<div class="heading-row"><div><h1>Your answers</h1><p class="subtitle">There are no right answers. Your responses are private.</p></div><span class="pill">${count} / 64 answered</span></div>
  <div class="progress" role="progressbar" aria-label="Questionnaire progress" aria-valuemin="0" aria-valuemax="64" aria-valuenow="${count}" style="margin:22px 0"><span style="width:${count / 64 * 100}%"></span></div>
  <nav class="tabs" aria-label="Question categories">${categories.map((c, i) => `<button class="btn ${i === state.category ? "" : "secondary"}" data-category="${i}" aria-current="${i === state.category ? "page" : "false"}">${i + 1}. ${esc(c)}</button>`).join("")}</nav>
  <section class="panel"><h2>${esc(categories[state.category])}</h2><p>Part ${state.category + 1} of 8. Choose the response that feels most like you. Each answer saves automatically.</p>
  ${questions.map(q => `<div class="question"><p><strong>${q.id}.</strong> ${esc(q.text)}</p><div class="scale" role="group" aria-label="${esc(q.text)}">${scale.map(([value, title]) => `<button type="button" data-answer="${q.id}" data-value="${value}" class="${state.me.answers[q.id] === value ? "selected" : ""}" aria-pressed="${state.me.answers[q.id] === value}">${title}</button>`).join("")}</div></div>`).join("")}
  <div class="form-actions">${state.category > 0 ? `<button class="btn secondary" data-category="${state.category - 1}">← Previous</button>` : ""}${state.category < 7 ? `<button class="btn" data-category="${state.category + 1}">Next category →</button>` : '<button class="btn" data-page="matches">Back to introductions</button>'}</div></section>`;
}

async function messagesPage() {
  if (state.chat) {
    const messages = await api(`/conversations/${state.chat.id}/messages`);
    return `<div class="heading-row"><div><h1>${esc(state.chat.name)}</h1><p class="subtitle">Respect each other's boundaries and take your time.</p></div><button class="btn secondary" data-action="back-chats">← All messages</button></div>
    <section class="panel" style="margin-top:25px"><div class="messages">${messages.length ? messages.map(m => `<div class="bubble ${m.mine ? "mine" : ""}"><p>${esc(m.body)}</p><small>${esc(new Date(m.created_at).toLocaleString())}</small></div>`).join("") : '<p class="hint">You both expressed interest. Say hello when you feel ready.</p>'}</div>
    <form id="message-form"><div class="field"><label for="message">Your message</label><textarea id="message" name="message" required maxlength="2000"></textarea></div><button class="btn">Send message</button></form>
    <div class="card-actions"><button class="link-button" data-action="unmatch" data-id="${state.chat.id}">Unmatch</button><button class="link-button" data-action="report" data-id="${state.chat.other_id}">Report</button><button class="link-button" data-action="block" data-id="${state.chat.other_id}">Block</button></div></section>`;
  }
  const conversations = await api("/conversations");
  return `<div class="heading-row"><div><h1>Your conversations</h1><p class="subtitle">Conversations open when interest is mutual.</p></div></div><div style="margin-top:25px">${conversations.length ? `<div class="chat-list">${conversations.map(c => `<button class="chat-item" data-chat="${c.id}" data-other="${c.other_id}" data-name="${esc(c.name)}"><strong>${esc(c.name)}</strong><span>${c.unread ? `${c.unread} unread` : "Open conversation →"}</span></button>`).join("")}</div>` : '<div class="empty"><h3>No conversations yet</h3><p>When you both like each other, your conversation will appear here.</p></div>'}</div>`;
}

function settingsPage() {
  return `<div class="heading-row"><div><h1>Settings & safety</h1><p class="subtitle">Manage your account and read our safety guidance.</p></div></div>
  <div class="grid-two" style="margin-top:25px"><div><section class="panel"><h2>Account</h2><p>Signed in as ${esc(state.me.email)}. Email status: ${state.me.verified ? "verified" : "not verified"}.</p>
  ${!state.me.verified ? `<button type="button" class="btn secondary" data-action="request-verification">Email a verification code</button><form id="verify-form">${field("code", "Verification code from email", "", "text", "required")}<button class="btn">Verify account</button></form>` : ""}
  <div class="form-actions"><button class="btn secondary" data-action="logout">Sign out</button></div></section>
  <section class="panel"><h2>Delete your account</h2><p>Deletes your profile, photos, answers, matches, conversations and messages. Reports remain with your account ID removed; their free text may still identify you.</p><form id="delete-form">${field("delete_password", "Confirm your password", "", "password", "required")}<button class="btn danger">Delete account permanently</button></form></section></div>
  <div><section class="panel"><h2>Community guidelines</h2><p>Be honest and kind. Respect consent and boundaries. Harassment, coercion, hate and impersonation aren't welcome. Never pressure someone to share personal information.</p><p>Meet in a public place, tell someone you trust, and leave whenever you feel uncomfortable. Use report or block on an introduction or conversation whenever you need to.</p></section>
  <section class="panel"><h2>Privacy</h2><form id="privacy-form"><label class="checkbox-line"><input name="matching_paused" type="checkbox" ${state.me.matching_paused ? "checked" : ""}> Pause my profile</label><p>Hides introductions and pauses conversations until you resume. Your existing selections and conversations stay saved.</p><button class="btn secondary">Save privacy</button></form><p>Your answers, email, birth date and exact coordinates are not shared with other users. Eligible introductions see your first name, age, coarse distance, intention, bio, interests, approved photo and compatibility breakdown.</p><p>This is a local development prototype, not a production privacy service. Don't enter sensitive or real personal information.</p></section></div></div>`;
}

function hasUnsavedChanges() {
  return !!document.querySelector('#profile-form[data-dirty="true"], #preferences-form[data-dirty="true"]');
}

for (const eventName of ["input", "change"]) {
  document.addEventListener(eventName, event => {
    const form = event.target.closest("#profile-form, #preferences-form");
    if (form) form.dataset.dirty = "true";
  });
}
window.addEventListener("beforeunload", event => {
  if (hasUnsavedChanges()) {
    event.preventDefault();
    event.returnValue = "";
  }
});

async function render() {
  if (!state.me) return authPage();
  app.innerHTML = '<div class="loading" role="status">Loading…</div>';
  try {
    let content;
    switch (state.page) {
      case "matches": content = await matchesPage(); break;
      case "profile": content = profilePage(); break;
      case "preferences": content = preferencesPage(); break;
      case "questionnaire": content = await questionnairePage(); break;
      case "messages": content = await messagesPage(); break;
      case "settings": content = settingsPage(); break;
      default: state.page = "matches"; content = await matchesPage();
    }
    shell(content);
  } catch (error) {
    shell(`<div class="empty" role="alert"><h3>Something didn't load.</h3><p>${esc(error.message)}</p><button class="btn" data-action="retry">Try again</button></div>`);
  }
}

document.addEventListener("click", async event => {
  const button = event.target.closest("button");
  if (!button || button.disabled) return;
  if (!button.dataset.page && button.dataset.category === undefined && !button.dataset.answer && !button.dataset.chat && !button.dataset.action) return;
  button.disabled = true;
  try {
    if (button.dataset.page) {
      if (hasUnsavedChanges() && !confirm("Discard your unsaved changes?")) return;
      state.page = button.dataset.page; state.chat = null; await render(); document.querySelector("#content")?.focus(); return;
    }
    if (button.dataset.category !== undefined) { state.category = Number(button.dataset.category); await render(); document.querySelector(`.tabs [data-category="${state.category}"]`)?.focus(); return; }
    if (button.dataset.answer) {
      const id = button.dataset.answer, value = Number(button.dataset.value);
      await api(`/answers/${id}`, { method: "PUT", body: { value } });
      state.me.answers[id] = value;
      await render();
      document.querySelector(`[data-answer="${id}"][data-value="${value}"]`)?.focus();
      return;
    }
    if (button.dataset.chat) {
      state.chat = { id: Number(button.dataset.chat), other_id: Number(button.dataset.other), name: button.dataset.name };
      await render(); return;
    }
    const action = button.dataset.action, id = button.dataset.id;
    if (action === "toggle-auth") { state.auth = state.auth === "login" ? "register" : "login"; authPage(); }
    else if (action === "restart-registration") { state.auth = "register"; authPage(); }
    else if (action === "dismiss-notice") { notice.className = ""; notice.textContent = ""; notice.setAttribute("role", "status"); }
    else if (action === "retry") await render();
    else if (action === "retry-start") await start();
    else if (action === "request-verification") { await api("/auth/verify/request", { method: "POST", body: {} }); toast("Check your email for a verification code."); }
    else if (action === "logout") { await api("/auth/logout", { method: "POST" }); state.me = null; state.questions = []; state.auth = "register"; authPage(); }
    else if (action === "back-chats") { state.chat = null; await render(); }
    else if (action === "like" || action === "pass") {
      if (action === "pass" && !confirm("Pass on this introduction? This decision is permanent in this prototype.")) return;
      await api(`/matches/${id}/reaction`, { method: "POST", body: { kind: action } }); toast(action === "like" ? "Interest saved." : "Passed."); await render();
    } else if (action === "block" || action === "report") {
      let reason;
      if (action === "block" && !confirm("Block this person? You will no longer see or message each other.")) return;
      if (action === "report") { reason = prompt("Tell us what happened (at least 5 characters):"); if (reason === null) return; }
      await api(`/safety/${id}`, { method: "POST", body: { kind: action, reason } });
      state.chat = null; toast("Safety action recorded."); await render();
    } else if (action === "unmatch") {
      if (!confirm("Unmatch and delete this conversation?")) return;
      await api(`/conversations/${id}/unmatch`, { method: "POST" }); state.chat = null; toast("Unmatched."); await render();
    }
  } catch (error) { toast(error.message, true); }
  finally { if (button.isConnected) button.disabled = false; }
});

document.addEventListener("submit", async event => {
  event.preventDefault();
  const form = event.target;
  if (form.dataset.pending) return;
  form.dataset.pending = "true";
  form.setAttribute("aria-busy", "true");
  const submit = event.submitter;
  if (submit) submit.disabled = true;
  const f = new FormData(form);
  try {
    if (form.id === "auth-form") {
      if (state.auth === "register") {
        state.authEmail = f.get("email");
        await api("/auth/register", { method: "POST", body: { email: state.authEmail } });
        state.auth = "activate";
      } else {
        const body = state.auth === "activate"
          ? { code: f.get("code"), password: f.get("password"), adult: f.has("adult") }
          : { email: f.get("email"), password: f.get("password") };
        await api(`/auth/${state.auth}`, { method: "POST", body });
        await refresh(); state.page = "matches"; toast("Welcome.");
      }
    } else if (form.id === "profile-form") {
      const lifestyle = Object.fromEntries(lifestyleKeys.map(k => [k, f.get(k)]));
      await api("/profile", { method: "PUT", body: { name: f.get("name"), birth_date: f.get("birth_date"), city: f.get("city"), latitude: Number(f.get("latitude")), longitude: Number(f.get("longitude")), bio: f.get("bio"), gender: f.get("gender"), intention: f.get("intention"), interests: f.get("interests").split(",").map(i => i.trim()).filter(Boolean), lifestyle } });
      await refresh(); toast("Profile saved.");
    } else if (form.id === "preferences-form") {
      const dealbreakers = Object.fromEntries(lifestyleKeys.map(k => [k, f.get(`deal_${k}`).trim()]).filter(([, v]) => v));
      await api("/preferences", { method: "PUT", body: { min_age: Number(f.get("min_age")), max_age: Number(f.get("max_age")), distance: Number(f.get("distance")), genders: f.getAll("genders"), intentions: f.getAll("intentions"), dealbreakers } });
      await refresh(); toast("Preferences saved.");
    } else if (form.id === "privacy-form") {
      await api("/privacy", { method: "PUT", body: { matching_paused: f.has("matching_paused") } });
      await refresh(); toast("Privacy preference saved.");
    } else if (form.id === "photo-form") {
      await api("/photo", { method: "POST", body: f }); await refresh(); toast("Photo submitted for review.");
    } else if (form.id === "verify-form") {
      await api("/auth/verify", { method: "POST", body: { code: f.get("code") } }); await refresh(); toast("Account verified.");
    } else if (form.id === "message-form") {
      await api(`/conversations/${state.chat.id}/messages`, { method: "POST", body: { body: f.get("message") } }); toast("Message sent.");
    } else if (form.id === "delete-form") {
      if (!confirm("Permanently delete your account and data?")) return;
      await api("/account", { method: "DELETE", body: { password: f.get("delete_password") } }); state.me = null; state.questions = []; toast("Account deleted.");
    } else return;
    await render();
  } catch (error) { toast(error.message, true); }
  finally {
    if (form.isConnected) {
      delete form.dataset.pending;
      form.removeAttribute("aria-busy");
      if (submit) submit.disabled = false;
    }
  }
});

async function start() {
  try { await refresh(); } catch (error) {
    state.me = null;
    if (error.status !== 401) {
      app.innerHTML = `<main id="content" class="auth-side"><div class="empty" role="alert"><h1>Unable to connect</h1><p>${esc(error.message)}</p><button class="btn" data-action="retry-start">Try again</button></div></main>`;
      return;
    }
  }
  await render();
}
start();
