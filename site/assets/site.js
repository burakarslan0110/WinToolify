/* Behaviour for the WinToolify site: scroll reveals, the hero's line-by-line
   paint, copy buttons and the terminal tour.

   No dependencies and no framework. Every effect here is decoration on top of
   markup that already reads correctly without it, so a blocked or failed
   script costs the visitor nothing but motion. */

(() => {
  'use strict';

  // Nothing is hidden until this file is running. If it is blocked, fails to
  // load, or is switched off, the page keeps every section visible instead of
  // waiting for an observer that will never fire.
  document.documentElement.dataset.js = '';

  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  /* ------------------------------------------------ language handover --- */

  // The two languages are separate documents, so following the switch would
  // otherwise drop the reader back at the top. What is carried across is the
  // section under the header and how far into it they had read, as a fraction:
  // both pages run the same sections, and a fraction survives the fact that
  // the same section is a different height in Turkish than in English.
  const HANDOVER = 'wt:lang-scroll';
  const LINE = 80;
  const docTop = (el) => el.getBoundingClientRect().top + window.scrollY;

  $$('.lang a').forEach((link) => {
    link.addEventListener('click', () => {
      const line = window.scrollY + LINE;
      let mark = { y: window.scrollY };
      $$('main section[id]').forEach((section) => {
        const top = docTop(section);
        if (top <= line) mark = { id: section.id, ratio: (line - top) / section.offsetHeight };
      });
      try { sessionStorage.setItem(HANDOVER, JSON.stringify(mark)); } catch { /* storage refused */ }
    });
  });

  try {
    const handover = sessionStorage.getItem(HANDOVER);
    if (handover) {
      sessionStorage.removeItem(HANDOVER);
      const mark = JSON.parse(handover);
      // Jump, never glide: this is the reader keeping their place, not moving.
      const land = () => {
        const root = document.documentElement;
        const behaviour = root.style.scrollBehavior;
        root.style.scrollBehavior = 'auto';
        const section = mark.id ? document.getElementById(mark.id) : null;
        const y = section ? docTop(section) + mark.ratio * section.offsetHeight - LINE : mark.y;
        window.scrollTo(0, Math.max(0, Math.round(y)));
        root.style.scrollBehavior = behaviour;
      };
      land();
      // The webfont settling can move things, so take the measurement again.
      window.addEventListener('load', land, { once: true });
    }
  } catch { /* nothing to restore */ }

  /* ---------------------------------------------------------- header --- */

  const top = $('.top');
  if (top) {
    const mark = () => top.classList.toggle('is-stuck', window.scrollY > 8);
    mark();
    window.addEventListener('scroll', mark, { passive: true });
  }

  /* --------------------------------------------------------- reveals --- */

  // Sections fade up as they arrive. Children of a .stagger run in sequence,
  // capped well under the point where the last item starts to feel late.
  $$('.stagger').forEach((group) => {
    Array.from(group.children).forEach((child, i) => {
      child.style.setProperty('--i', String(Math.min(i, 8)));
    });
  });

  const revealables = $$('.reveal');
  if (reduced.matches || !('IntersectionObserver' in window)) {
    revealables.forEach((el) => el.classList.add('is-in'));
  } else {
    const revealer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add('is-in');
          revealer.unobserve(entry.target);
        });
      },
      { rootMargin: '0px 0px -12% 0px', threshold: 0.05 },
    );
    revealables.forEach((el) => revealer.observe(el));
  }

  /* ------------------------------------------------------- name types --- */

  // The name is typed out by the caret that follows it. The h1 carries the
  // whole word as its accessible name, so nothing is lost while it is short.
  const typed = $('.wordmark__text');
  if (typed && !reduced.matches) {
    const word = typed.textContent;
    typed.textContent = '';
    let at = 0;
    const tick = () => {
      typed.textContent = word.slice(0, (at += 1));
      if (at < word.length) window.setTimeout(tick, 78);
    };
    window.setTimeout(tick, 260);
  }

  /* --------------------------------------------------- terminal paint --- */

  // Frames arrive row by row, the way the console fills a screen, rather than
  // appearing all at once.
  // The tour's five screens share one window, so there the screen is the panel
  // and not the .term around it; everywhere else the two are the same element.
  const tourFrames = new Set($$('.tour__frames > [role="tabpanel"]'));
  // The hero window is left out: its player does its own arming, and arming it
  // twice would nest every row inside the one before it.
  const heroFrames = $$('.hero__frames > [data-hero]');
  const screens = [
    ...$$('.term').filter((term) => !term.closest('.tour__stage') && !$('.hero__frames', term)),
    ...tourFrames,
  ].filter((el) => $('.term__body', el));

  // A transcript is not a screen being painted, it is a conversation arriving.
  // Pausing on the blank lines and on each tool call gives it that rhythm
  // instead of a single even crawl.
  const chatDelay = (text, previous) => {
    const line = text.trim();
    if (!line) return previous + 150;
    if (line.startsWith('●')) return previous + 230;
    if (line.startsWith('⎿')) return previous + 170;
    return previous + 40;
  };

  const arm = (screen) => {
    const body = $('.term__body', screen);
    if (!body || body.dataset.rows) return;
    const chat = screen.dataset.stream === 'chat';
    let at = 0;
    body.innerHTML = body.innerHTML
      .split('\n')
      .map((line, i) => {
        const style = chat
          ? `animation-delay:${(at = chatDelay(line.replace(/<[^>]*>/g, ''), at))}ms`
          : `--i:${i}`;
        return `<span class="type-line" style="${style}">${line || '&nbsp;'}</span>`;
      })
      .join('');
    body.dataset.rows = '1';
    screen.classList.add('is-armed');
  };

  // Removing the class and reading a layout property before adding it back
  // restarts the animation, so a screen repaints every time it is shown.
  const paint = (screen) => {
    screen.classList.remove('is-typed');
    void screen.offsetWidth;
    screen.classList.add('is-typed');
  };

  if (!reduced.matches && 'IntersectionObserver' in window) {
    screens.forEach(arm);

    // The tour's screens are stacked on top of each other, so they all count as
    // on screen at once. They are painted by the tour instead, when shown.
    const painter = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          paint(entry.target);
          painter.unobserve(entry.target);
        });
      },
      { threshold: 0.12 },
    );
    screens.forEach((screen) => { if (!tourFrames.has(screen)) painter.observe(screen); });
  }

  /* ------------------------------------------------- hero walkthrough --- */

  // Five screens, and most of the time is spent doing the work rather than
  // walking to it: two services marked one row at a time and applied, three
  // privacy settings the same, the records both applies wrote, then the
  // assistant. The menu is only ever passed through. One lap is about
  // twenty-four seconds.
  //
  // The console does not repaint a screen to move a cursor, it rewrites the
  // rows that changed and leaves the rest alone (Write-WtFrame diffs against
  // the previous frame). This does the same: moving the cursor rewrites two
  // rows, marking a row rewrites one, and only a change of screen touches
  // them all.
  if (heroFrames.length && !reduced.matches) {
    const HOLD = [
      700,                          // the main menu, already on Services
      850, 650, 450, 650, 1300,     // the list, marked, down, marked, applied
      400,                          // through the menu to Privacy
      800, 500, 500, 450, 600, 1300, // the list, three marked one by one, applied
      400, 1400,                    // through the menu to the records they wrote
      400,                          // through the menu to the assistant
      1200, 900, 2900, 500, 3200,   // greeting, question, answer, "1", result
    ];
    const shots = heroFrames.map((f) => $('.term__body', f).innerHTML.split('\n'));
    const stage = heroFrames[0].parentElement;
    const typed = JSON.parse(stage.dataset.typing || '[]');

    // Only the first panel stays: the others were just a place to keep the
    // rows, and with no script they are the no-JS fallback that never runs.
    heroFrames.slice(1).forEach((f) => f.remove());
    const screen = heroFrames[0];
    const body = $('.term__body', screen);
    body.innerHTML = shots[0].map((l, i) => `<span class="type-line" style="--i:${i}">${l || '&nbsp;'}</span>`).join('');
    body.dataset.rows = '1';
    screen.classList.add('is-armed', 'is-on');
    const rows = $$('.type-line', body);

    const marks = $$('.hero__steps .hero__step');
    let at = 0;
    let timer = 0;
    let onScreen = true;

    const markCurrent = () => {
      marks.forEach((mark) => {
        const owns = mark.dataset.frames.split(',').includes(String(at));
        if (owns) mark.setAttribute('aria-current', 'true');
        else mark.removeAttribute('aria-current');
      });
    };

    const redraw = (next, skip) => {
      let changed = 0;
      shots[next].forEach((line, i) => {
        if (i === skip || line === shots[at][i]) return;
        rows[i].innerHTML = line || '&nbsp;';
        rows[i].animate(
          [{ opacity: 0.15 }, { opacity: 1 }],
          { duration: 150, delay: changed * 6, easing: 'cubic-bezier(.22,.61,.36,1)', fill: 'backwards' },
        );
        changed += 1;
      });
      at = next;
      markCurrent();
      return changed;
    };

    // A question is not painted onto the screen, it is typed into it, so that
    // row is filled a character at a time with the console's own block caret
    // sitting after the last one.
    const type = (spec, done) => {
      const row = rows[spec.row];
      const pad = (n) => ' '.repeat(Math.max(0, 91 - 4 - n - 1));
      let n = 0;
      const beat = () => {
        const head = spec.text.slice(0, n);
        row.innerHTML =
          `<span class="t-c">  &gt; ${head.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</span>` +
          (n < spec.text.length ? `<span class="t-sel"> </span>` : '') +
          `<span class="t-gr">${pad(head.length)}</span>`;
        if (n < spec.text.length) { n += 1; window.setTimeout(beat, 42); return; }
        row.innerHTML = shots[at][spec.row];
        done();
      };
      beat();
    };

    // Held only when there is nobody to watch: the window is off screen or the
    // tab is in the background. It used to hold on hover as well, but the
    // window fills most of the screen, so the pointer sits on it most of the
    // time and the recording looked stuck.
    const waiting = () => document.hidden || !onScreen;

    const after = (ms, fn) => { window.clearTimeout(timer); timer = window.setTimeout(fn, ms); };

    const tick = () => {
      if (waiting()) { after(400, tick); return; }
      const next = (at + 1) % shots.length;
      const spec = typed.find((s) => s.at === next);
      const changed = redraw(next, spec ? spec.row : -1);
      const wait = changed * 6 + 150;
      if (spec) {
        after(wait, () => type(spec, () => after(HOLD[next], tick)));
        return;
      }
      after(wait + HOLD[next], tick);
    };

    // Clicking a screen name jumps the recording there and carries on.
    marks.forEach((mark) => {
      mark.addEventListener('click', () => {
        const to = Number(mark.dataset.jump);
        const spec = typed.find((s) => s.at === to);
        redraw(to, spec ? spec.row : -1);
        if (spec) { type(spec, () => after(HOLD[to], tick)); return; }
        after(HOLD[to], tick);
      });
    });

    const window_ = screen.closest('.term');
    document.addEventListener('visibilitychange', () => { if (!document.hidden) after(200, tick); });

    let started = false;
    const watcher = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          onScreen = entry.isIntersecting;
          if (!onScreen || started) return;
          started = true;
          markCurrent();
          paint(screen);                       // the console filling up once
          after(rows.length * 30 + HOLD[0], tick);
        });
      },
      { threshold: 0.05 },
    );
    watcher.observe(window_);
  }

  /* ------------------------------------------------------------ copy --- */

  $$('[data-copy]').forEach((button) => {
    const done = button.dataset.done || 'Copied';
    const idle = button.textContent;
    button.addEventListener('click', async () => {
      const target = document.getElementById(button.dataset.copy);
      if (!target) return;
      try {
        await navigator.clipboard.writeText(target.textContent.trim());
      } catch {
        // Clipboard access can be refused outright; select the text so the
        // visitor can still copy it by hand rather than leaving them stuck.
        const range = document.createRange();
        range.selectNodeContents(target);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        return;
      }
      button.textContent = done;
      button.classList.add('is-done');
      window.setTimeout(() => {
        button.textContent = idle;
        button.classList.remove('is-done');
      }, 1800);
    });
  });

  /* ------------------------------------------------------------ tour --- */

  const tour = $('.tour');
  if (tour) {
    const tabs = $$('.tour__step', tour);
    // The window's own tab strip: a second way to the same screens, so it
    // carries aria-current rather than a tab role the steps already hold.
    const dots = $$('.term__tab', tour);
    const panels = $$('.tour__frames > [role="tabpanel"]', tour);
    let current = -1;

    const show = (index) => {
      const next = Math.max(0, Math.min(index, tabs.length - 1));
      if (next === current) return;
      current = next;
      tabs.forEach((tab, i) => {
        tab.setAttribute('aria-selected', String(i === current));
        tab.tabIndex = i === current ? 0 : -1;
      });
      // The dots are a second way into the same panels, not a second tablist,
      // so they carry aria-current rather than a role they do not have.
      dots.forEach((dot, i) => {
        if (i === current) dot.setAttribute('aria-current', 'true');
        else dot.removeAttribute('aria-current');
      });
      panels.forEach((panel, i) => panel.classList.toggle('is-on', i === current));
      if (!reduced.matches) paint(panels[current]);
    };

    const jump = (index) => {
      show(index);
      tabs[current].scrollIntoView({
        behavior: reduced.matches ? 'auto' : 'smooth',
        block: 'center',
      });
    };

    tabs.forEach((tab, i) => {
      tab.addEventListener('click', () => show(i));
      tab.addEventListener('keydown', (event) => {
        const step = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[event.key];
        if (!step) return;
        event.preventDefault();
        const next = (current + step + tabs.length) % tabs.length;
        tabs[next].focus();
        jump(next);
      });
    });

    dots.forEach((dot, i) => dot.addEventListener('click', () => jump(i)));

    // Scrolling past a step selects it: whichever step is crossing the middle
    // of the viewport wins, so the frame always matches what is being read.
    if ('IntersectionObserver' in window) {
      const watcher = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (entry.isIntersecting) show(tabs.indexOf(entry.target));
          });
        },
        { rootMargin: '-45% 0px -45% 0px', threshold: 0 },
      );
      tabs.forEach((step) => watcher.observe(step));
    }

    show(0);
  }
})();
