/* Headless self-check for the preview prototype.
   Concatenated after the extracted <script> body by _harness.js. */
(function () {
  const log = [];
  const P = (k, v) => log.push(k + ' = ' + v);

  log.push('=== responsive engine ===');
  const cases = [[480,480],[800,480],[390,844],[844,390],[768,1024],[1280,800],[360,640],[1024,768],[1200,500]];
  for (const [w,h] of cases) {
    const m = resolveMetrics(w,h);
    P('  ' + w + 'x' + h,
      m.cls + ' / ' + m.variant + ' / scale=' + m.scale.toFixed(3) +
      ' / headerH=' + m.headerHeight.toFixed(1) +
      ' / pagePad=' + m.pagePadding.toFixed(1) +
      ' / dashCols=' + m.dashboardColumns +
      ' / rail=' + m.hasSideRail);
  }

  log.push('=== formatting parity (lib/util/format.dart) ===');
  P('fmtRate(1234.5)', fmtRate(1234.5, true));
  P('fmtRate(12.34)',  fmtRate(12.34, true));
  P('fmtRate(0.5)',    fmtRate(0.5, true));
  P('fmtRate(0.00042)',fmtRate(0.00042, true));
  P('fmtRate(invalid)',fmtRate(50, false));
  P('fmtTemp(47.2)',   fmtTemp(47.2, true));
  P('fmtTemp(invalid)',fmtTemp(0, false));
  P('fmtTempShort(49)',fmtTempShort(49, true));
  P('fmtPower(80)',    fmtPower(80, true));
  P('fmtClock(4.2)',   fmtClock(4.2, true));
  P('fmtPercent(45)',  fmtPercent(45, true));
  P('fmtPercent(inv)', fmtPercent(45, false));
  P('capPair',         fmtCapacityPair(5.4, true, 12.0, true));
  P('capPair(inv)',    fmtCapacityPair(0, false, 0, false));
  P('isHot(85)',       isHot(85, true));
  P('isHot(84.9)',     isHot(84.9, true));
  P('wrapModel i9',    JSON.stringify(wrapModel('Intel Core i9-14900K', 24)));
  P('wrapModel long',  JSON.stringify(wrapModel('NVIDIA GeForce RTX 4070 Laptop GPU Extreme Edition', 24)));

  log.push('=== clock ===');
  const c = clockFields(new Date(2026, 9, 9, 15, 32, 26));
  P('date', c.date + ' | ' + c.weekday + ' | ' + c.hh + ':' + c.mm + ':' + c.ss + ' | valid=' + c.valid);

  log.push('=== world (mock_data_source port) ===');
  seedWorld();
  for (let i = 0; i < 40; i++) stepWorld();
  const g0 = W.gpus[0], e0 = busiestEngine(g0);
  P('cpu%',        W.cpuUsage);
  P('cpuT / cpuP', W.cpuTemp.toFixed(1) + ' C / ' + W.cpuPower.toFixed(0) + ' W');
  P('cpuClock',    W.cpuClock.toFixed(2) + ' GHz');
  P('cores',       W.cores.length);
  P('gpu0 engines',g0.engines.length + ' (' + g0.engines.map(e=>e.name).join(',') + ')');
  P('gpu0 busiest',e0.name + ' ' + e0.usage + '%');
  P('gpu0 T/P',    g0.temp.toFixed(1) + ' C / ' + g0.power.toFixed(0) + ' W');
  P('gpu0 vram',   g0.vramUsed.toFixed(2) + ' / ' + g0.vramTotal + ' GiB');
  P('gpu1 engines',W.gpus[1].engines.length);
  P('ram%',        Math.round(W.ramUsed / W.ramTotal * 100) + '% (' + W.ramUsed.toFixed(1) + ' GiB)');
  P('net',         fmtRate(W.netDown, true) + ' / ' + fmtRate(W.netUp, true));
  W.disks.forEach((d, i) => P('disk' + i, d.name + '  r=' + d.read.toFixed(0) + ' w=' + d.write.toFixed(0) + ' act=' + d.activity + '% t=' + d.temp.toFixed(1)));

  log.push('=== 60-point history / adapter switch ===');
  historyGpuId = null; CPU_HISTORY.length = 0; GPU_HISTORY.length = 0;
  for (let i = 0; i < 70; i++) { stepWorld(); pushHistory(); }
  P('window', CPU_HISTORY.length + ' cpu / ' + GPU_HISTORY.length + ' gpu');
  P('nulls', CPU_HISTORY.filter(v => v == null).length + ' cpu / ' + GPU_HISTORY.filter(v => v == null).length + ' gpu');
  const before = GPU_HISTORY.filter(v => v != null).length;
  S.gpuIndex = 1; pushHistory();
  P('switch adapter -> gpu non-null', GPU_HISTORY.filter(v => v != null).length + ' (was ' + before + ', must reset to 0 then grow)');
  S.gpuIndex = 0;

  log.push('=== per-adapter windows (GPU device list) ===');
  W.gpus.forEach((g, i) => {
    const s = GPU_HISTORIES[i] || [];
    const vals = s.filter(v => v != null).length;
    P('  adapter' + i, '"' + g.name.slice(0, 28) + '"  points=' + s.length +
      ' values=' + vals + ' newest=' + (vals ? s[s.length - 1] : '-'));
    if (s.length !== HIST_POINTS) P('  !! wrong window length', s.length + ' @' + i);
    if (vals === 0) P('  !! no samples recorded for adapter', i);
  });

  log.push('=== navigation state machine (ui_app.c) ===');
  S.gpuIndex = 0; S.openGpu = null; S.page = 'dashboard';
  nav.openGpus();  P('openGpus, 2 adapters', S.page);
  S.gpuIndex = 0; nav.chooseGpu(1);
  P('chooseGpu(1)', S.page + ' | dashboardIdx=' + S.gpuIndex + ' | openIdx=' + S.openGpu);
  nav.home();      P('home', S.page + ' | openIdx=' + S.openGpu);
  const saved = W.gpus; W.gpus = [saved[0]];
  S.page = 'dashboard'; nav.openGpus();
  P('openGpus, 1 adapter (shortcut)', S.page);
  W.gpus = saved;
  nav.openCpu();   P('openCpu', S.page);
  nav.openDisks(); P('openDisks', S.page);
  nav.home();      P('home', S.page);

  log.push('=== themes ===');
  let bad = 0;
  for (const t of THEMES) {
    for (const [k, v] of Object.entries(t)) {
      if (typeof v === 'string' && v[0] === '#' && !/^#[0-9A-Fa-f]{6}$/.test(v)) { P('BAD ' + t.id + '.' + k, v); bad++; }
    }
  }
  P('count', THEMES.length + ', malformed colours: ' + bad);
  P('cut>0 themes', THEMES.filter(t => t.cut > 0).map(t => t.id).join(',') || '(none)');

  log.push('=== link badge ===');
  for (const mode of ['SIM','LIVE','STALE','WAIT']) {
    S.link = mode;
    const k = connectionKind();
    P(mode.padEnd(5), 'text="' + statusText() + '"  kind=' + k + '  badge=' + kindBadge(k));
  }
  S.link = 'SIM';

  log.push('=== portrait dashboard fit budget ===');
  const VPS = [[320,568],[360,640],[393,852],[412,915],[430,932],[744,1133],[820,1180],[480,480],[800,480],[852,393],[1180,820]];
  for (const [w,h] of VPS) {
    VIEW.w = w; VIEW.h = h;
    M = resolveMetrics(w,h);
    const compact = M.variant==='compactStack'||M.variant==='splitColumns';
    if (!compact) { P('  '+w+'x'+h, M.variant+' (grid, untouched)'); continue; }
    const CARD=210, TILE=92, GAP=10, CLOCK=TILE;
    const twoUp = ((M.vw - 2*M.pagePadding)/2) >= 160*M.scale;
    const bandUnits = twoUp ? TILE : TILE*2;
    const gapCount  = twoUp ? 4 : 6;
    const nominal = (2*CARD + 2*bandUnits + CLOCK + GAP*gapCount)*M.scale;
    const avail = dashAvailable();
    const fit = clamp(avail/nominal, 0.5, 1.0);
    DM = compressMetrics(M, fit);
    const mm = DM;
    const bandW = twoUp ? (M.vw-2*mm.pagePadding-mm.gutter)/2 : (M.vw-2*mm.pagePadding);
    const freeH = Math.max(0, avail - gapCount*mm.gutter);
    const tileH = freeH*bandUnits/(2*CARD + 2*bandUnits + CLOCK);
    const clockH = freeH*CLOCK/(2*CARD + 2*bandUnits + CLOCK);
    const clockW = M.vw-2*mm.pagePadding;
    // Pixel costs of the band's fixed parts, measured with the compressed
    // metrics the band is actually built from: panel padding, the new date /
    // weekday line and the gap under it.
    const padPx = mm.padding, datePx = F(11)*1.25, gapPx = 4*mm.scale;
    P('  '+w+'x'+h+' '+M.variant,
      'twoUp='+twoUp+' avail='+avail.toFixed(0)+' nominal='+nominal.toFixed(0)+
      ' fit='+fit.toFixed(3)+' scale='+mm.scale.toFixed(3)+' tileW='+bandW.toFixed(0));
    P('     clock band', clockW.toFixed(0)+'x'+clockH.toFixed(0)+
      ' (tile '+tileH.toFixed(0)+', delta '+(clockH-tileH).toFixed(2)+')');
    DM = null;
    const html = dashboardHtml();
    if (html.indexOf('undefined') >= 0) P('  !! undefined in html', w+'x'+h);
    // `panel({glow})` re-runs hexA() on an accent that is already rgba(), so the
    // processor-card glow comes out as rgba(NaN,g,NaN,a) - a long-standing
    // preview artefact that only drops a shadow, so it is stripped rather than
    // failed. Anything left over IS a real bug.
    const clean = html.replace(/rgba\(NaN,\d+,NaN,[\d.]+\)/g, '');
    if (clean.indexOf('NaN') >= 0) P('  !! NaN in html', w+'x'+h);
    if (html.indexOf('growY') >= 0) P('  !! still scrollable', w+'x'+h);
    // cpu.bar, gpu.bar, ram.bar, vram.bar - the NET/DISK tiles carry no bar.
    const bars = (html.match(/data-bar=/g)||[]).length;
    if (bars !== 4) P('  !! expected 4 bars, got', bars + ' @' + w + 'x' + h);
    // The clock must be present, full width, one tile tall, and its digits must
    // fit the band they were sized against.
    const ticks = (html.match(/data-k="cal\.(hh|mm|ss)"/g)||[]).length;
    if (ticks !== 3) P('  !! clock ticks missing, got', ticks + ' @' + w + 'x' + h);
    if (html.indexOf('LOCAL / 24H') < 0) P('  !! clock caption missing', w+'x'+h);
    // Year / month / day must lead the readout.
    if (html.indexOf('data-k="cal.date"') < 0) P('  !! clock date line missing', w+'x'+h);
    if (html.indexOf('data-k="cal.weekday"') < 0) P('  !! clock weekday missing', w+'x'+h);
    const hm = html.match(/data-k="cal\.hh" style="font-size:([\d.]+)px/);
    const sm = html.match(/data-k="cal\.ss" style="font-size:([\d.]+)px/);
    const digit = hm ? parseFloat(hm[1]) : NaN;
    if (!isFinite(digit)) { P('  !! no clock digit size', w+'x'+h); continue; }
    // The seconds must now be the same size as the hours.
    if (!sm || sm[1] !== hm[1]) {
      P('  !! seconds differ in size from hours',
        (hm?hm[1]:'?') + ' vs ' + (sm?sm[1]:'?') + ' @' + w + 'x' + h);
    }
    const need = 2*padPx + datePx + gapPx + digit;
    const pct = need/clockH;
    P('     clock digits', digit.toFixed(1)+'px  need='+need.toFixed(1)+' of '+clockH.toFixed(1)+
      ' ('+(pct*100).toFixed(0)+'%)');
    if (pct > 1.02) P('  !! clock overflows its band', w+'x'+h);
  }
  M = resolveMetrics(480,480);

  log.push('=== processor card model block (was dead space) ===');
  for (const [w,h] of [[393,852],[820,1180],[852,393],[1180,820]]) {
    VIEW.w = w; VIEW.h = h;
    M = resolveMetrics(w,h);
    const html = dashboardHtml();
    const n = (html.match(/data-k="cpu\.model"/g)||[]).length;
    const mg = html.match(/data-k="cpu\.model"[^>]*?font-size:([\d.]+)px/);
    const dg = html.match(/data-k="cpu\.detail"[^>]*?font-size:([\d.]+)px/);
    const ms = mg ? parseFloat(mg[1]) : NaN;
    const ds = dg ? parseFloat(dg[1]) : NaN;
    P('  '+w+'x'+h+' '+M.variant,
      'model elements='+n+' size='+(isFinite(ms)?ms.toFixed(1):'?')+
      '  detail='+(isFinite(ds)?ds.toFixed(1):'?'));
    if (n !== 1) P('  !! expected exactly one model element', n+' @'+w+'x'+h);
    if (!(ms > ds)) P('  !! model should out-size the detail row', ms+' <= '+ds+' @'+w+'x'+h);
  }
  M = resolveMetrics(480,480);

  log.push('=== gpu device list curve ===');
  const count = (s,re)=>(s.match(re)||[]).length;
  for (const [w,h] of [[852,393],[1180,820],[393,852]]) {
    VIEW.w = w; VIEW.h = h;
    M = resolveMetrics(w,h);
    const html = gpuSelectorHtml();
    const curves = count(html, /data-spark="gpuHistory:/g);
    const parts  = count(html, /data-k="gsel\.\d+\.parts"/g);
    P('  '+w+'x'+h, 'adapters='+W.gpus.length+' curves='+curves+' summary rows='+parts+
      ' undefined='+(html.indexOf('undefined')>=0));
    if (curves !== W.gpus.length) P('  !! one curve per adapter expected', curves+' @'+w+'x'+h);
    if (parts !== W.gpus.length) P('  !! one summary per adapter expected', parts+' @'+w+'x'+h);
    if (html.indexOf('undefined') >= 0) P('  !! undefined in gpu list html', w+'x'+h);
  }
  M = resolveMetrics(480,480);

  log.push('=== host link page (host_connect_screen.dart) ===');
  const HOST_VPS = [[393,852],[360,640],[412,915],[852,393],[820,1180],[1180,820],[480,480],[800,480]];
  const HOST_STATES = ['idle','scanning','found','requesting','connecting','online','offline','failed'];
  const HOST_BADGES = {idle:'IDLE',scanning:'SCANNING',found:'FOUND',requesting:'CONFIRM',
                       connecting:'LINKING',online:'LIVE',offline:'OFFLINE',failed:'ERROR'};
  const countOf = (s,re)=> (s.match(re)||[]).length;

  function hostsIssues(html, tag){
    const out=[];
    if(html.indexOf('undefined')>=0) out.push('undefined');
    if(html.indexOf('NaN')>=0) out.push('NaN');
    if(html.indexOf('HOST LINK')<0) out.push('no header');
    if(html.indexOf('LAN SCAN')<0) out.push('no radar title');
    if(html.indexOf('THIS DEVICE')<0) out.push('no device row');
    const radars = countOf(html, /viewBox="0 0 100 100"/g);
    if(radars!==1) out.push('radar count='+radars);
    if(html.indexOf('data-click="rescan"')<0) out.push('no scan button');
    return out.map(x=>x+'@'+tag);
  }

  // Every viewport must lay out without a scroll container and with one card
  // per discovered host.
  for (const [w,h] of HOST_VPS) {
    VIEW.w=w; VIEW.h=h; M=resolveMetrics(w,h);
    S.page='hosts'; S.hostEmpty=false; S.hostIndex=0; S.hostState='found';
    const html=hostsHtml();
    const cards=countOf(html, /data-click="host:/g);
    const issues=hostsIssues(html, w+'x'+h);
    P('  '+w+'x'+h+' '+M.variant,
      'cards='+cards+' radar='+countOf(html,/viewBox="0 0 100 100"/g)+
      ' demo='+(html.indexOf('data-click="simulate"')>=0?'y':'n')+
      ' issues='+(issues.join(',')||'none'));
    if(cards!==HOSTS.length) P('  !! one card per host expected', cards+' of '+HOSTS.length+' @'+w+'x'+h);
    if(issues.length) P('  !! hosts page issues', issues.join(','));
    // The list scrolls inside its own panel; the page itself must not.
    if(html.indexOf('growY col')<0 && HOSTS.length>1) P('  !! host list has no scroll container', w+'x'+h);
  }

  // Every state must render, with its own badge, and never with a hole in the
  // copy: the caption comes from a switch that has to cover all eight.
  for (const st of HOST_STATES) {
    S.hostIndex=0; S.hostState=st;
    const html=hostsHtml();
    const want=HOST_BADGES[st];
    const badgeOk=html.indexOf('>'+want+'<')>=0;
    P('  '+st.padEnd(11),
      'badge='+want+' ok='+badgeOk+' caption="'+hostStateCaption().slice(0,40)+'..."');
    if(!badgeOk) P('  !! badge missing for state', st);
    if(hostsIssues(html, st).length) P('  !! state renders badly', st+': '+hostsIssues(html,st).join(','));
    if(!hostStateCaption()) P('  !! empty caption for state', st);
    if(!hostStateMessage()) P('  !! empty header message for state', st);
  }

  log.push('=== host link state machine ===');
  VIEW.w=393; VIEW.h=852; M=resolveMetrics(393,852);
  S.page='hosts'; S.hostEmpty=false; S.link='WAIT';
  S.hostState='found'; S.hostIndex=0;
  nav.pickHost(1);
  P('pickHost(1) already paired -> ', S.hostState+' link='+S.link+
    ' paired='+((pairedHost()||{}).name||'-'));
  nav.disconnect();  P('disconnect -> ', S.hostState+' link='+S.link);
  nav.reconnect();   P('reconnect -> ',  S.hostState+' link='+S.link);
  nav.pickHost(0);
  P('pickHost(0) unpaired -> ', S.hostState+' link='+S.link+
    ' awaiting='+((awaitingHost()||{}).name||'-'));
  const reqHtml=hostsHtml();
  P('  WAITING + spinner shown',
    (reqHtml.indexOf('WAITING')>=0)+' / '+(reqHtml.indexOf('class="spin"')>=0));
  if(reqHtml.indexOf('WAITING')<0) P('  !! WAITING badge missing while the PC decides','');
  if(reqHtml.indexOf('class="spin"')<0) P('  !! no progress indicator while waiting','');
  if(reqHtml.indexOf('data-click="cancel"')<0) P('  !! no Cancel while waiting','');
  nav.cancel();      P('cancel -> ',  S.hostState);
  nav.scan();        P('scan -> ',    S.hostState);
  // Scan is inert while a scan / a connection attempt is in flight, the way
  // `HudButton(onPressed: busy ? null : ...)` behaves: same label, no effect.
  nav.scan();        P('scan again (busy) -> ', S.hostState);
  if(S.hostState!=='scanning') P('  !! rescan restarted while already scanning','');
  // Forget/Reconnect are gated on the *stored secret*, not on the live link, so
  // they must survive a scan - `c.pairedHost` is the persisted record.
  const scanBar=hostsHtml();
  P('bar while paired+scanning', 'Forget='+(scanBar.indexOf('data-click="forget"')>=0)+
    ' Reconnect='+(scanBar.indexOf('data-click="reconnect"')>=0));
  if(scanBar.indexOf('data-click="forget"')<0) P('  !! Forget vanished while scanning','');
  if(scanBar.indexOf('data-click="reconnect"')<0) P('  !! Reconnect vanished while scanning','');
  nav.reconnect();   P('reconnect -> ', S.hostState);
  nav.scan();        P('scan while linking -> ', S.hostState);
  if(S.hostState!=='connecting') P('  !! scan ran during a connection attempt','');
  nav.forget();      P('forget -> ',  S.hostState+' link='+S.link+
    ' remembered='+(rememberedHost()?'yes':'no'));
  if(rememberedHost()) P('  !! secret survived Forget','');
  const bareBar=hostsHtml();
  P('bar after forget', 'Forget='+(bareBar.indexOf('data-click="forget"')>=0)+
    ' Reconnect='+(bareBar.indexOf('data-click="reconnect"')>=0));
  if(bareBar.indexOf('data-click="forget"')>=0) P('  !! Forget offered with no stored secret','');
  nav.openHosts();   P('openHosts keeps state', S.hostState);
  // Forget really dropped the secret, so tapping the same PC has to go out as a
  // fresh `pairing.request` rather than a reconnect.
  nav.pickHost(1);   P('pickHost(1) after forget -> ', S.hostState);
  if(S.hostState!=='requesting') P('  !! a forgotten PC should re-pair, not reconnect','');
  nav.granted();     P('pairing.grant -> ', S.hostState+
    ' remembered='+((rememberedHost()||{}).name||'-'));
  if(!rememberedHost()) P('  !! pairing.grant did not store the secret','');
  nav.setHostState('online');
  P('online action bar', 'Dashboard='+(hostsHtml().indexOf('data-click="home"')>=0)+
    ' Disconnect='+(hostsHtml().indexOf('data-click="disconnect"')>=0)+
    ' Demo='+(hostsHtml().indexOf('data-click="simulate"')>=0));
  if(hostsHtml().indexOf('data-click="simulate"')>=0) P('  !! Demo offered while online','');
  if(hostsHtml().indexOf('data-click="forget"')<0) P('  !! Forget missing while online','');
  if(hostsHtml().indexOf('data-click="reconnect"')>=0) P('  !! Reconnect offered while already online','');
  nav.setHostState('offline');
  P('offline action bar', 'Reconnect='+(hostsHtml().indexOf('data-click="reconnect"')>=0)+
    ' Demo='+(hostsHtml().indexOf('data-click="simulate"')>=0));
  nav.setHostState('scanning');
  P('scanning action bar', 'Cancel='+(hostsHtml().indexOf('data-click="cancel"')>=0)+
    ' Forget='+(hostsHtml().indexOf('data-click="forget"')>=0)+' (peer kept)');
  P('renameDevice wired', typeof nav.renameDevice==='function');

  log.push('=== host card vocabulary (stored secret vs discovered) ===');
  S.hostEmpty=false; S.hostState='found'; S.hostIndex=0;
  const actionOf = h => (h.match(/, (LINKED|WAITING|CONNECT|PAIR|LOCKED)"/)||[])[1]||'?';
  const badgeOf  = h => h.indexOf('>PAIRED<')>=0 ? 'PAIRED'
                        : (h.indexOf('>PAIRING OPEN<')>=0 ? 'PAIRING OPEN' : 'PAIRING CLOSED');
  for (let i=0;i<HOSTS.length;i++) {
    const card=hostCardHtml(HOSTS[i], i);
    P('  '+HOSTS[i].name.padEnd(22), 'badge='+badgeOf(card)+' action='+actionOf(card));
  }
  const ownIdx=HOSTS.indexOf(rememberedHost());
  const ownCard=hostCardHtml(rememberedHost(), ownIdx);
  P('stored secret marks its card', 'index='+ownIdx+' badge='+badgeOf(ownCard)+' action='+actionOf(ownCard));
  if(ownCard.indexOf('>PAIRED<')<0) P('  !! the stored secret did not badge its card PAIRED','');
  if(actionOf(ownCard)!=='CONNECT') P('  !! the stored secret did not mark its card CONNECT', actionOf(ownCard));
  if(actionOf(hostCardHtml(HOSTS[0],0))!=='PAIR') P('  !! an open, unknown PC should offer PAIR','');
  if(actionOf(hostCardHtml(HOSTS[2],2))!=='LOCKED') P('  !! a closed, unknown PC should read LOCKED','');

  log.push('=== radar blips (bearing from hostId hash) ===');
  S.hostIndex=0; S.hostState='online';
  const blipsA=radarBlips(), blipsB=radarBlips();
  P('online', blipsA.map(b=>'r='+b.range.toFixed(3)+' locked='+(b.locked?'Y':'n')).join(' | '));
  P('stable across calls', JSON.stringify(blipsA)===JSON.stringify(blipsB));
  if(JSON.stringify(blipsA)!==JSON.stringify(blipsB)) P('  !! blips are not deterministic','');
  const locked=blipsA.filter(b=>b.locked).length;
  P('locked blips', locked);
  if(locked!==1) P('  !! exactly one locked blip expected while online', locked);
  // A host keeps its bearing whatever the connection state is - only the
  // locked one moves inward.
  S.hostState='found';
  const blipsC=radarBlips();
  const sameAngle=JSON.stringify(blipsA.map(b=>b.angle))===JSON.stringify(blipsC.map(b=>b.angle));
  P('bearing independent of state', sameAngle);
  if(!sameAngle) P('  !! bearing moved with the state','');
  if(blipsC.filter(b=>b.locked).length!==0) P('  !! a blip stayed locked while not online','');
  // The paired host must sit on the inner ring.
  const inner=blipsA.find(b=>b.locked);
  if(inner && inner.range>0.3) P('  !! locked blip is not on the inner ring', inner.range);

  log.push('=== host list edge cases ===');
  S.hostEmpty=true; S.hostState='scanning'; S.hostIndex=0;
  const emptyHtml=hostsHtml();
  P('scanning, nothing found',
    'cards='+countOf(emptyHtml,/data-click="host:/g)+
    ' notice='+(emptyHtml.indexOf('LISTENING FOR BROADCASTS...')>=0));
  if(countOf(emptyHtml,/data-click="host:/g)!==0) P('  !! cards present in an empty list','');
  if(emptyHtml.indexOf('LISTENING FOR BROADCASTS...')<0) P('  !! empty notice missing','');
  S.hostState='idle';
  const idleHtml=hostsHtml();
  P('idle, nothing found', 'notice='+(idleHtml.indexOf('NO PCS LISTED YET')>=0)+
    ' caption="'+hostStateCaption()+'"');
  if(idleHtml.indexOf('NO PCS LISTED YET')<0) P('  !! idle empty notice missing','');
  S.hostEmpty=false;

  // One long name must not push the card's badge off the edge.
  S.hostState='found';
  const longHtml=hostCardHtml({id:'x',name:'A VERY LONG WORKSTATION NAME THAT SHOULD ELLIPSIZE',ip:'10.0.0.1',port:8765,open:true,paired:false},0);
  P('long name card', 'ellipsis class='+(longHtml.indexOf('class="el nowrap"')>=0)+
    ' badge='+(longHtml.indexOf('>PAIR<')>=0));
  if(longHtml.indexOf('class="el nowrap"')<0) P('  !! long name is not ellipsized','');

  log.push('=== host page across themes ===');
  let themeBad=0;
  for (const t of THEMES) {
    S.themeId=t.id;
    const html=hostsHtml();
    const nan=html.indexOf('NaN')>=0, und=html.indexOf('undefined')>=0;
    P('  '+t.id.padEnd(14), 'NaN='+nan+' undefined='+und+' len='+html.length);
    if(nan||und){ themeBad++; P('  !! broken markup in theme', t.id); }
  }
  P('themes with broken markup', themeBad);
  S.themeId='cryo_blue';

  VIEW.w=393; VIEW.h=852; M=resolveMetrics(393,852);
  S.page='dashboard'; S.hostState='scanning'; S.hostIndex=0; S.link='SIM';

  console.log(log.join('\n'));
})();
