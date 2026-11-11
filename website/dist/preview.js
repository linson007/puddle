'use strict';

// This is a browser-local illustration of the native app, never a connected workspace.
const escapePreview = value => String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
const previewTasks = [
  {id:'onboarding', title:'Refine the onboarding flow', owner:'', notes:'Product · Today', focused:true, completed:false},
  {id:'launch', title:'Review the launch checklist', owner:'', notes:'Project Puddle · Today', focused:true, completed:false},
  {id:'focus', title:'Make space for deep work', owner:'', notes:'Personal · 2:00 PM', focused:true, completed:false},
  {id:'followup', title:'Follow up with the design team', owner:'Maya', notes:'Follow up Monday', waiting:true, focused:false, completed:false}
];
const previewMain = ['today','chat','tasks','memory'];
const previewWork = ['calendar','mail','meetings','actions'];
const previewWorkspace = ['portfolio','browser','routines','knowledge','history'];
const previewPins = new Set();
let previewProfile = 'personal';
let previewMore = false;
let currentView = 'today';
let previewTaskFilter = 'open';
let previewNote = 'Alex: Keep the first release focused on the core experience.\nMira: I will review the onboarding checklist by Friday.';
let previewNoteDraft = previewNote;
const previewButton = (label, attributes = '') => `<button type="button" class="demo-button" ${attributes}>${label}</button>`;
const previewHeading = (title, subtitle, action = '') => `<div class="demo-title-row"><h2>${title}</h2>${action}</div><p class="demo-subtitle">${subtitle}</p>`;
const previewFootnote = text => `<p class="demo-freshness">${text} · Sample data only</p>`;
function previewTaskRow(task) {
  return `<div class="demo-task ${task.completed ? 'is-complete' : ''}"><button type="button" class="${task.completed ? 'complete' : ''}" data-demo-task="${task.id}" aria-label="${task.completed ? 'Reopen' : 'Complete'} ${escapePreview(task.title)}" aria-pressed="${task.completed}"></button><div><div class="demo-task-text">${escapePreview(task.title)}</div><div class="demo-task-meta">${task.waiting ? 'Waiting on ' : task.owner ? 'Owner: ' : ''}${escapePreview(task.owner || task.notes)}</div></div>${!task.completed ? `<button type="button" class="demo-priority ${task.focused ? 'is-focused' : ''}" data-demo-priority="${task.id}" aria-label="${task.focused ? 'Remove priority:' : 'Prioritize'} ${escapePreview(task.title)}" aria-pressed="${task.focused}">${task.focused ? '★' : '☆'}</button>` : ''}</div>`;
}
const previewDefinitions = {
  today: {title:'Today', icon:'sun', content:() => {
    const priorities = previewTasks.filter(task => task.focused && !task.completed);
    return `<div class="demo-date">WEDNESDAY, 11 NOVEMBER · SAMPLE DAY</div>${previewHeading('Your day, in focus.', 'A few things that matter. A little room to breathe.', previewButton('+ New task', 'data-new-task'))}<div class="demo-layout"><div class="demo-panel"><h3>${icon('sun')} Your priorities <span class="demo-tag">${priorities.length} / 3</span></h3><p class="panel-hint">Three things. One clear starting point.</p>${priorities.map(previewTaskRow).join('') || '<p class="demo-empty">What would make today feel successful? Star up to three tasks to keep them here.</p>'}${previewButton('Choose from tasks', 'data-preview-nav="tasks"')}</div><div class="demo-panel"><h3>${icon('calendar')} Today's agenda</h3><p class="panel-hint">Cached calendar · Sample day</p><div class="demo-event"><span>10:00 – 10:30</span><b>Product sync</b><small>Prepare with saved notes</small></div><div class="demo-event"><span>14:00 – 15:30</span><b>A little time to focus</b></div>${previewButton('Open Calendar', 'data-preview-nav="calendar"')}</div></div><div class="demo-brief"><div>${icon('spark')} Ready when you are.</div>${previewButton('End-of-day review', 'data-demo-brief')}${previewButton('Brief me on today', 'data-demo-brief')}</div>${previewFootnote('Saved work & cached connections')}`;
  }},
  tasks: {title:'Tasks', icon:'tasks', content:() => {
    const matches = previewTasks.filter(task => previewTaskFilter === 'completed' ? task.completed : !task.completed && (previewTaskFilter !== 'waiting' || task.waiting));
    return `${previewHeading('A little more follow-through.', "Your next actions, reminders and the people you're waiting on.", previewButton('+ New task', 'data-new-task'))}<div class="demo-filter" role="group" aria-label="Show commitments">${[['open','Open'],['waiting','Waiting on'],['completed','Completed']].map(([key,label]) => `<button type="button" data-task-filter="${key}" aria-pressed="${previewTaskFilter === key}">${label}</button>`).join('')}</div><p class="demo-subtitle">${matches.length} ${previewTaskFilter === 'waiting' ? 'waiting on' : previewTaskFilter} · Star up to three priorities for today</p><div class="demo-panel">${matches.map(previewTaskRow).join('') || '<p class="demo-empty">No tasks in this view.</p>'}</div>${previewFootnote('Try adding, completing, reopening or prioritizing a sample task')}`;
  }},
  meetings: {title:'Meetings', icon:'meet', content:() => `${previewHeading('Meetings', 'Open a meeting from your calendar or paste an invitation link.')}<div class="demo-panel"><h3>Your meeting notes</h3><div class="demo-editor-toolbar"><b>Product sync</b><span id="preview-note-status">${previewNoteDraft === previewNote ? 'Saved locally' : 'Unsaved changes'}</span>${previewButton('Save', `data-save-note ${previewNoteDraft === previewNote ? 'disabled' : ''}`)}</div><label class="demo-field">Your notes<textarea id="preview-note" rows="4">${escapePreview(previewNoteDraft)}</textarea></label><details class="demo-details"><summary>Local meeting summary</summary><div class="demo-note-summary"><strong>DECISION</strong><p>Keep the first release focused on the core experience.</p><blockquote>“Keep the first release focused on the core experience.”<span class="demo-quote-source">Source: sample notes</span></blockquote></div><p>Actions are reviewed before becoming commitments. Live transcription requires macOS 26+, an installed speech language and permission.</p></details></div>${previewFootnote('Native drafts stay editable during saves; quitting with unsaved notes prompts you')}`},
  mail: {title:'Mail', icon:'mail', content:() => `${previewHeading('Mail', 'Your recent inbox, with room to focus.')}<div class="demo-filter"><span>Gmail · Sample account</span>${previewButton('Review sample reply', 'data-review-reply')}</div><div class="demo-panel"><h3>Your recent inbox</h3>${[['AJ','Alex Jordan','Launch checklist, ready for a look'],['MS','Maya Shah','A few thoughts from our product sync'],['LP','Lee Park','Next week’s agenda']].map(([initials,name,subject]) => `<div class="demo-mail-row"><span class="demo-avatar">${initials}</span><div><b>${name}</b><p>${subject}</p></div><small>Unread</small></div>`).join('')}</div>${previewFootnote('Up to 50 recent inbox messages; opening mail keeps its provider read status')}`},
  calendar: {title:'Calendar', icon:'calendar', content:() => `${previewHeading('Calendar', 'Your agenda and the context for what’s next.')}<div class="demo-filter" role="group" aria-label="Calendar preview">${previewButton('Agenda', 'data-calendar-view="agenda"')}${previewButton('Week & Month', 'data-calendar-view="week"')}</div><div id="preview-calendar-body">${previewAgenda()}</div>${previewFootnote('Google Calendar · Provider writes require exact-content review')}`},
  chat: {title:'Puddle', icon:'chat', content:() => `${previewHeading('Puddle', `${previewProfile === 'developer' ? 'Developer' : 'Personal'} · Local model · Scripted example`)}<div class="demo-chat"><div class="demo-bubble user-bubble">Read my saved tasks and tell me the next action and owner.</div><div class="demo-receipt">${icon('check')} Read tasks · completed</div><div class="demo-bubble assistant-bubble"><img src="assets/puddle.svg" alt="" width="23" height="23"><div>Your next step is to review the onboarding flow. Maya owns the design-team follow-up. You can find both in Tasks.</div></div></div><div class="demo-brief">A conversation, on your Mac. ${previewButton('Open Tasks', 'data-preview-nav="tasks"')}</div>${previewFootnote('Illustrative tool receipt and answer; this website does not run a model')}`},
  memory: {title:'Memory', icon:'brain', content:() => `${previewHeading('What Puddle remembers', 'Review existing memories, forget them, or add a memory manually.')}<div class="demo-panel"><div class="demo-memory"><h4>Working style</h4><p>“I work best with a little focus time before meetings.”</p><small>Source: your message · Editable in the app</small></div><div class="demo-memory"><h4>Response preference</h4><p>“I prefer short, practical answers.”</p><small>Source: your message · Editable in the app</small></div></div>${previewFootnote('No visitor information is learned by this preview')}`},
  developer: {title:'Developer', icon:'code', content:() => `${previewHeading('Developer workspace', 'Bring source evidence, changes and debugging context into your local assistant.')}<div class="demo-panel"><h3>Connected project <span class="demo-tag">Read-only</span></h3><div class="demo-source-tree">▾ Sources<br>　▾ PuddleCore<br>　　AssistantProfiles.swift<br>　　Agent.swift<br>▸ Tests</div><h3>Development sessions</h3><p class="demo-subtitle">Keep the problem, reproduction, findings and verification evidence together.</p><div class="demo-note-summary"><strong>REVIEW CHANGES</strong><p>Inspect source and record findings before deciding on the next step.</p></div></div>${previewFootnote('Project files stay read-only; Puddle does not change code or run tests')}`},
  actions: {title:'Actions', icon:'check', content:() => `${previewHeading('Actions', 'Review drafts and inspect what happened. An interrupted action never replays automatically.')}<div class="demo-panel"><h3>Reply: Launch checklist</h3><p class="demo-subtitle">Draft · Sample account</p>${previewButton('Review Exact Contents', 'data-review-reply')}<hr><h3>Create event: Product sync</h3><p class="demo-subtitle">Completed · Illustrative provider receipt</p></div>${previewFootnote('Review, dispatch and receipts are separate steps in the native app')}`},
  portfolio: {title:'Work Context', icon:'folder', content:() => `${previewHeading('Projects, people &amp; decisions', 'Projects, people and decisions behind your next action.')}<div class="demo-panel"><h3>Projects</h3><div class="demo-memory"><h4>Puddle launch</h4><p>Keep the first release focused on the everyday experience.</p></div><h3>People & decisions</h3><p class="demo-subtitle">Maya · Design review<br>Decision: prioritize onboarding and follow-through.</p></div>${previewFootnote('Owners record context; assigning one does not contact them')}`},
  browser: {title:'Browser', icon:'globe', content:() => `${previewHeading('Browser', 'Read and summarize pages with Puddle in a separate browser, powered by Cua.')}<div class="demo-panel"><h3>Connect Cua Driver</h3><p class="demo-subtitle">Puddle can open addresses and scroll. Take over in the browser to click links, fill forms or sign in.</p><p class="demo-subtitle">Start a separate browser session explicitly in the native app. Assistant navigation and scrolling wait for review.</p></div>${previewFootnote('The website does not connect a driver or operate your browser')}`},
  routines: {title:'Routines', icon:'repeat', content:() => `${previewHeading('Routines', 'Scheduled read-only briefs and reviews.')}<div class="demo-panel"><h3>Morning brief <span class="demo-tag">Paused sample</span></h3><p class="demo-subtitle">Saved work, priorities and cached connections.<br>Review run history in the native app. Nothing sends mail or changes tasks.</p></div>${previewFootnote('Routines require Puddle or its menu-bar process to be running')}`},
  knowledge: {title:'Knowledge', icon:'book', content:() => `${previewHeading('Knowledge', 'Search selected local files and keep the sources close.')}<div class="demo-panel"><h3>Your selected sources</h3><div class="demo-memory"><h4>Product notes</h4><p>Text and Markdown · Selected folder</p><small>Indexed locally · Cited extracted passages</small></div><div class="demo-memory"><h4>Research library</h4><p>PDF and DOCX · Selected files</p></div></div>${previewFootnote('Only files and folders you select are indexed')}`},
  history: {title:'History', icon:'chat', content:() => `${previewHeading('History', 'Search and reopen saved conversations.')}<div class="demo-panel"><h3>Planning the release</h3><p class="demo-subtitle">Read tasks, review next actions and return to the conversation.</p>${previewButton('Open conversation', 'data-preview-nav="chat"')}</div>${previewFootnote('Profiles share your conversations')}`},
  connections: {title:'Connections', icon:'connections', content:() => `${previewHeading('Connections', 'Connect the tools you use, at your own pace.')}<div class="demo-panel"><h3>Google & Outlook</h3><p class="demo-subtitle">Optional mail and calendar accounts. Review scopes and switch accounts explicitly.</p><h3>Work sources</h3><p class="demo-subtitle">GitHub · Jira · Confluence<br>Choose repositories and sites for read-only context.</p></div>${previewFootnote('No accounts are connected by this website')}`},
  settings: {title:'Settings', icon:'settings', content:() => `${previewHeading('Settings', 'Local AI, assistant preferences, privacy, backups and updates.')}<div class="demo-panel"><h3>Local AI</h3><p class="demo-subtitle">Connect a running server, then test replies and tool calling.</p><h3>Privacy & recovery</h3><p class="demo-subtitle">Save or discard existing notes before starting a private session. Ending it discards private meeting and development drafts.</p><h3>Backups</h3><p class="demo-subtitle">Use a passphrase-encrypted export and review merges before restoring.</p></div>${previewFootnote('These settings describe the native app; no device settings change here')}`}
};
function previewAgenda() { return '<div class="demo-panel"><h3>Today</h3><div class="demo-event"><span>10:00 – 10:30</span><b>Product sync</b><small>Meeting notes ready</small></div><div class="demo-event"><span>14:00 – 15:30</span><b>Focus time</b></div></div>'; }
function previewWeek() { return `<div class="demo-calendar">${['MON','TUE','WED','THU','FRI'].map((day,index) => `<div class="demo-calendar-day">${day}<b>${9+index}</b>${index === 2 ? '<div class="demo-calendar-event">10:00<br>Product sync</div><div class="demo-calendar-event purple">14:00<br>Focus time</div>' : ''}</div>`).join('')}</div>`; }
function previewNavRow(key, pinnable = false) {
  const definition = previewDefinitions[key];
  const count = key === 'tasks' ? previewTasks.filter(task => !task.completed).length : 0;
  return `<div class="preview-nav-row"><button type="button" class="preview-nav-button ${currentView === key ? 'active' : ''}" data-preview-nav="${key}" ${currentView === key ? 'aria-current="page"' : ''}>${icon(definition.icon)}${definition.title}${count ? `<span>${count}</span>` : ''}</button>${pinnable ? `<button type="button" class="preview-pin" data-preview-pin="${key}" aria-label="${previewPins.has(key) ? 'Unpin' : 'Pin'} ${definition.title}" aria-pressed="${previewPins.has(key)}">${icon('pin')}</button>` : ''}</div>`;
}
function renderPreviewNavigation() {
  const workspace = previewProfile === 'developer' ? ['developer', ...previewWorkspace] : previewWorkspace;
  const extras = [...previewWork, ...workspace];
  document.querySelector('#preview-sidebar').innerHTML = previewMain.map(key => previewNavRow(key)).join('') + extras.filter(key => previewPins.has(key)).map(key => previewNavRow(key,true)).join('') + `<button type="button" class="preview-more" aria-expanded="${previewMore}" aria-controls="preview-more-items" data-preview-more>${previewMore ? '⌄' : '›'} ${icon('more')} More</button><div id="preview-more-items" ${previewMore ? '' : 'hidden'}>${[['Work',previewWork],['Workspace',workspace]].map(([label,keys]) => `<div class="sidebar-section-label">${label}</div>${keys.filter(key => !previewPins.has(key)).map(key => previewNavRow(key,true)).join('')}`).join('')}</div>`;
  document.querySelector('#preview-utilities').innerHTML = ['connections','settings'].map(key => previewNavRow(key)).join('');
  document.querySelector('#preview-profile').value = previewProfile;
}
function renderPreview(view) {
  if (!previewDefinitions[view]) return;
  if (view === 'developer') previewProfile = 'developer';
  currentView = view;
  if (![...previewMain,'connections','settings'].includes(view) && !previewPins.has(view)) previewMore = true;
  const model = previewDefinitions[view];
  const content = document.querySelector('#preview-content');
  content.innerHTML = model.content();
  content.setAttribute('aria-label', `${model.title} — illustrative Puddle preview`);
  document.querySelector('#preview-breadcrumb').textContent = model.title;
  renderPreviewNavigation();
  document.querySelectorAll('[data-view]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.view === view)));
}
const previewDialog = document.querySelector('#preview-dialog');
function openPreviewDialog(title, body) {
  document.querySelector('#preview-dialog-title').textContent = title;
  document.querySelector('#preview-dialog-body').innerHTML = body;
  if (!previewDialog.open) previewDialog.showModal();
}
function openPreviewSearch() {
  openPreviewDialog('Search workspace and commands', '<label class="demo-field">Search<input id="preview-search-input" placeholder="Search work or type a command…" autocomplete="off"></label><div id="preview-search-results"></div><p class="demo-freshness">Sample workspace only · Esc to close</p>');
  renderPreviewSearch('');
  document.querySelector('#preview-search-input').focus();
}
function renderPreviewSearch(query) {
  const items = Object.entries(previewDefinitions).filter(([key,definition]) => (key !== 'developer' || previewProfile === 'developer') && definition.title.toLowerCase().includes(query.trim().toLowerCase()));
  document.querySelector('#preview-search-results').innerHTML = items.map(([key,definition]) => previewButton(`Open ${definition.title}`, `data-search-destination="${key}"`)).join('') || '<p>No matching workspaces. Try Tasks, Meetings or Memory.</p>';
}
document.querySelectorAll('[data-view]').forEach(button => button.addEventListener('click', () => renderPreview(button.dataset.view)));
document.querySelector('#preview-profile').addEventListener('change', event => {
  previewProfile = event.target.value;
  renderPreview(previewProfile !== 'developer' && currentView === 'developer' ? 'today' : currentView);
});
document.querySelector('.preview-controls').addEventListener('keydown', event => {
  if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
  const buttons = [...document.querySelectorAll('[data-view]')];
  const index = buttons.indexOf(document.activeElement);
  if (index < 0) return;
  event.preventDefault();
  const next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + buttons.length) % buttons.length;
  buttons[next].focus(); buttons[next].click();
});
document.querySelector('.app-window').addEventListener('click', event => {
  const nav = event.target.closest('[data-preview-nav]');
  if (nav) { renderPreview(nav.dataset.previewNav); document.querySelector(`#preview-sidebar [data-preview-nav="${currentView}"], #preview-utilities [data-preview-nav="${currentView}"]`)?.focus({preventScroll:true}); return; }
  if (event.target.closest('[data-preview-more]')) { previewMore = !previewMore; renderPreviewNavigation(); document.querySelector('[data-preview-more]').focus({preventScroll:true}); return; }
  const pin = event.target.closest('[data-preview-pin]');
  if (pin) { const key = pin.dataset.previewPin; previewPins.has(key) ? previewPins.delete(key) : previewPins.add(key); renderPreviewNavigation(); document.querySelector(`[data-preview-pin="${key}"]`)?.focus({preventScroll:true}); return; }
  const task = event.target.closest('[data-demo-task]');
  const priority = event.target.closest('[data-demo-priority]');
  if (task || priority) {
    const item = previewTasks.find(item => item.id === (task?.dataset.demoTask || priority.dataset.demoPriority));
    if (task) { item.completed = !item.completed; item.focused = false; }
    else if (item.focused) item.focused = false;
    else if (previewTasks.filter(task => task.focused && !task.completed).length < 3) item.focused = true;
    else { toast('Choose up to three sample priorities for today.'); return; }
    renderPreview(currentView);
    (document.querySelector(`[data-demo-task="${item.id}"]`) || document.querySelector('#preview-content [data-demo-task]') || document.querySelector('[data-new-task]'))?.focus({preventScroll:true});
    return;
  }
  const filter = event.target.closest('[data-task-filter]');
  if (filter) { previewTaskFilter = filter.dataset.taskFilter; renderPreview('tasks'); document.querySelector(`[data-task-filter="${previewTaskFilter}"]`).focus(); return; }
  if (event.target.closest('[data-new-task]')) {
    openPreviewDialog('New commitment', '<form id="preview-task-form"><label class="demo-field">Next action<input name="title" required maxlength="200" autofocus></label><label class="demo-field">Status<select name="status"><option value="open">My next action</option><option value="waiting">Waiting on someone</option></select></label><label class="demo-field">Owner (required for waiting-on tasks)<input name="owner" maxlength="100"></label><p class="demo-freshness">Sample task held in page memory. No notification is scheduled.</p><button class="demo-button dark" type="submit">Save Commitment</button></form>');
    return;
  }
  if (event.target.closest('[data-demo-search]')) { openPreviewSearch(); return; }
  if (event.target.closest('[data-demo-brief]')) { renderPreview('chat'); return; }
  if (event.target.closest('[data-save-note]')) { previewNote = previewNoteDraft; renderPreview('meetings'); toast('Sample notes saved for this page session.'); return; }
  const calendar = event.target.closest('[data-calendar-view]');
  if (calendar) { document.querySelector('#preview-calendar-body').innerHTML = calendar.dataset.calendarView === 'week' ? previewWeek() : previewAgenda(); return; }
  if (event.target.closest('[data-review-reply]')) openPreviewDialog('Review this action', '<div class="demo-panel"><p><b>To:</b> alex@example.test</p><p><b>Subject:</b> Re: Launch checklist</p><p>I will review the onboarding checklist before Friday.</p></div><p class="demo-freshness">In Puddle, you review exact recipients and content before sending. This preview never sends email.</p><button type="button" class="demo-button" data-close-dialog>Close sample review</button>');
});
document.querySelector('.app-window').addEventListener('input', event => {
  if (event.target.id !== 'preview-note') return;
  previewNoteDraft = event.target.value;
  const dirty = previewNoteDraft !== previewNote;
  document.querySelector('#preview-note-status').textContent = dirty ? 'Unsaved changes' : 'Saved locally';
  document.querySelector('[data-save-note]').disabled = !dirty;
});
document.querySelector('.app-window').addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); openPreviewSearch(); }
});
previewDialog.addEventListener('click', event => {
  if (event.target.closest('[data-close-dialog]')) previewDialog.close();
  const destination = event.target.closest('[data-search-destination]');
  if (destination) { previewDialog.close(); renderPreview(destination.dataset.searchDestination); document.querySelector(`[data-preview-nav="${currentView}"]`)?.focus(); }
});
previewDialog.addEventListener('input', event => {
  if (event.target.id === 'preview-search-input') renderPreviewSearch(event.target.value);
  const form = event.target.closest('#preview-task-form');
  if (form) { form.elements.owner.setCustomValidity(''); form.elements.title.setCustomValidity(''); }
});
previewDialog.addEventListener('submit', event => {
  if (event.target.id !== 'preview-task-form') return;
  event.preventDefault();
  const form = event.target;
  const title = form.elements.title.value.trim();
  const owner = form.elements.owner.value.trim();
  const waiting = form.elements.status.value === 'waiting';
  if (!title || (waiting && !owner)) { (title ? form.elements.owner : form.elements.title).setCustomValidity(title ? 'Add who you are waiting on.' : 'Enter a next action.'); form.reportValidity(); return; }
  previewTasks.push({id:`sample-${previewTasks.length}`,title,owner,waiting,notes:'Captured in this preview',focused:false,completed:false});
  previewTaskFilter = 'open'; previewDialog.close(); renderPreview('tasks');
  toast('Sample commitment added. No real task or reminder was created.');
});
renderPreview('today');
