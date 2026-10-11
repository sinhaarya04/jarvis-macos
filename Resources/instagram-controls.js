// Fixed browser adapter. Models receive observed labels and can choose only indexed controls.
// No model output is evaluated as code, selectors, URLs or keyboard shortcuts.
function jarvisInstagram(request) {
  const fail = message => { throw new Error(message); };
  if (location.protocol !== 'https:' || !['www.instagram.com','instagram.com'].includes(location.hostname))
    fail('The Instagram tab changed to another website.');
  const visible = el => {
    const r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return el.isConnected && r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 &&
      r.top < innerHeight && r.left < innerWidth && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const label = el => (el.getAttribute('aria-label') || el.getAttribute('placeholder') ||
    el.getAttribute('aria-placeholder') || el.innerText ||
    Array.from(el.querySelectorAll('svg title,img[alt]')).map(n=>n.textContent || n.alt).join(' ')).trim().slice(0,250);
  const value = el => el.isContentEditable ? el.innerText : (el.value || '');
  const handle = href => {
    try {
      const u = new URL(href, location.href);
      if (!['www.instagram.com','instagram.com'].includes(u.hostname) || u.protocol !== 'https:' || u.search) return '';
      const m = u.pathname.match(/^\/([a-z0-9_.]{1,30})\/?$/i);
      return m && !['direct','explore','accounts','reels','p','stories','legal'].includes(m[1]) ? m[1].toLowerCase() : '';
    } catch { return ''; }
  };
  const editors = () => Array.from(document.querySelectorAll('[contenteditable="true"][role="textbox"],textarea')).filter(visible);
  const conversation = editor => {
    for (let parent = editor.parentElement; parent && parent !== document.body; parent = parent.parentElement) {
      const headers = Array.from(parent.querySelectorAll('a[aria-label^="Open the profile page of "]')).filter(visible);
      if (headers.length) {
        const recipients = [...new Set(headers.map(a=>handle(a.href)).filter(Boolean))];
        const fields = editors().filter(el=>parent.contains(el));
        return recipients.length === 1 && fields.length === 1 ? {parent, recipient:recipients[0], editor} : null;
      }
    }
    return null;
  };
  if (request.mode === 'snapshot') {
    const nodes = [], controls = [];
    const add = (el, kind, extra={}) => {
      if (!visible(el) || el.disabled || el.getAttribute('aria-disabled') === 'true') return;
      const id = nodes.length;
      nodes.push(el);
      controls.push({id,kind,label:label(el),value:kind === 'searchField' || kind === 'composer' ? value(el) : '',href:el.href || '',recipient:'',...extra});
    };
    for (const el of document.querySelectorAll('a,button,[role="button"],input')) {
      const name = label(el);
      if (el.tagName === 'INPUT' && /search/i.test(name)) add(el,'searchField');
      else if (/^search(?: search)?$/i.test(name)) add(el,'search');
      else if (/^message$/i.test(name) && !location.pathname.startsWith('/direct/')) add(el,'message');
      else if (el.tagName === 'A') {
        const h = handle(el.href);
        // Search result rows carry a profile picture plus a textual handle, unlike image-only links.
        if (h && el.innerText.trim() && !el.querySelector('h1,h2')) add(el,'profile',{recipient:h});
      }
    }
    for (const editor of editors()) {
      const chat = conversation(editor);
      if (!chat) continue;
      add(editor,'composer',{recipient:chat.recipient});
      for (const el of chat.parent.querySelectorAll('button,[role="button"]')) {
        if (/^send$/i.test(label(el))) add(el,'send',{recipient:chat.recipient});
      }
    }
    const nonce = crypto.randomUUID();
    const profile = handle(location.href);
    const profileVisible = !!profile && Array.from(document.querySelectorAll('h1,h2')).some(n=>n.innerText.trim().toLowerCase() === profile);
    window.__jarvisInstagram = {nonce,nodes,controls,url:location.href,time:Date.now(),used:false};
    return {url:location.href,nonce,controls,profile:profileVisible ? profile : '',
      loginRequired:location.pathname.startsWith('/accounts/login'),
      searchValue:controls.find(c=>c.kind==='searchField')?.value || ''};
  }
  const state = window.__jarvisInstagram;
  if (!state || state.used || state.nonce !== request.nonce || state.url !== location.href ||
      request.url !== location.href || Date.now()-state.time > 15000) fail('The page changed. Please repeat the command.');
  const control = state.controls.find(c=>c.id === request.id), el = state.nodes[request.id];
  if (!control || !el || !visible(el) || label(el) !== control.label || (el.href || '') !== control.href ||
      el.disabled || el.getAttribute('aria-disabled') === 'true') fail('The selected control changed.');
  const r = el.getBoundingClientRect();
  const top = document.elementFromPoint(Math.max(0,Math.min(innerWidth-1,r.left+r.width/2)),Math.max(0,Math.min(innerHeight-1,r.top+r.height/2)));
  if (!top || !(el===top || el.contains(top))) fail('Another window on the page covers that control.');
  if (control.kind === 'composer' || control.kind === 'send') {
    const chat = editors().map(conversation).find(c=>c && c.recipient === request.recipient && c.parent.contains(el));
    if (!chat || control.recipient !== request.recipient) fail('The message recipient changed. Nothing was sent.');
    if (control.kind === 'send' && value(chat.editor) !== request.text) fail('The draft changed. Nothing was sent.');
  }
  if (request.operation === 'fill') {
    if (!['searchField','composer'].includes(control.kind) || typeof request.text !== 'string' || request.text.length > 2000)
      fail('That field cannot accept this command.');
    if (control.kind === 'composer' && value(el) !== '') fail('There is already a draft in this chat. Review it first.');
    state.used = true; // Consume before mutation. A failed action is never automatically retried.
    el.focus();
    if (el.isContentEditable) {
      if (!document.execCommand('insertText', false, request.text)) fail('Instagram did not accept the draft.');
    } else {
      const setter = Object.getOwnPropertyDescriptor(el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype,'value').set;
      setter.call(el,request.text);
      el.dispatchEvent(new Event('input',{bubbles:true}));
      el.dispatchEvent(new Event('change',{bubbles:true}));
    }
    return {ok:true};
  }
  if (request.operation !== 'click' || !['search','profile','message','send'].includes(control.kind)) fail('Unsupported browser action.');
  if (control.kind === 'profile' && control.recipient !== request.recipient) fail('The chosen profile changed.');
  if (control.kind === 'message' && handle(location.href) !== request.recipient) fail('The profile changed.');
  if (control.kind === 'send' && request.allowSend !== true) fail('Sending requires an explicit send command.');
  state.used = true;
  el.click();
  return {ok:true};
}
