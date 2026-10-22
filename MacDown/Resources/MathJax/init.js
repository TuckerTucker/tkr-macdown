// MacDown MathJax 3 configuration.
//
// Loaded BEFORE es5/tex-mml-chtml.js: MathJax 3 reads `window.MathJax` as its
// configuration when its startup component runs.
//
// - In the in-app preview this file is an external script served from
//   x-macdown-asset: (the preview's Content-Security-Policy forbids inline
//   scripts). In exported HTML it is inlined, followed by MathJax from the
//   jsDelivr CDN with Subresource Integrity.
// - Completion is announced with a DOM event, `macdown:mathjax-end`, on
//   `document`. The native bridge lives in an isolated content world that
//   page scripts cannot reach; DOM events cross content worlds, so the
//   bridge's own user script listens for the event and forwards it. This
//   file never touches any native messaging API, so in a browser (exported
//   HTML) the event is simply unobserved.
// - The event fires exactly once, whether typesetting succeeds, fails, or
//   MathJax never loads at all: the host waits for it to finish loading and
//   must never hang.
(function () {
    'use strict';

    var END_EVENT = 'macdown:mathjax-end';

    // Upper bound on how long the page may keep the host waiting after the
    // window `load` event if MathJax neither finishes nor fails.
    var END_TIMEOUT_MS = 15000;

    var ended = false;
    function signalEnd() {
        if (ended)
            return;
        ended = true;
        var event;
        try {
            event = new CustomEvent(END_EVENT);
        } catch (e) {
            event = document.createEvent('CustomEvent');
            event.initCustomEvent(END_EVENT, false, false, null);
        }
        document.dispatchEvent(event);
    }

    // The preview is served from MacDown's own schemes and ships only the
    // MathJax pieces vendored under Resources/MathJax (see VERSION there).
    // The contextual menu lazily loads components that are not vendored
    // (a11y explorer, speech rule engine, SVG output), so it is disabled in
    // the preview. Exported HTML loads from the CDN, where everything is
    // reachable, and keeps the menu.
    var inPreview = /^x-macdown-/.test(window.location.protocol);

    window.MathJax = {
        loader: {
            // MathJax 2's TeX-AMS-MML_HTMLorMML config rendered TeX errors
            // as the original source (noErrors). Keep that behaviour.
            load: ['[tex]/noerrors']
        },
        tex: {
            packages: {'[+]': ['noerrors']},
            // hoedown's math extension always emits \( \) and \[ \]
            // (HOEDOWN_EXT_MATH_EXPLICIT only changes how *it* parses `$`),
            // so these are MathJax 2's tex2jax defaults, kept verbatim.
            inlineMath: [['\\(', '\\)']],
            displayMath: [['$$', '$$'], ['\\[', '\\]']],
            processEscapes: false
        },
        options: {
            enableMenu: !inPreview
        },
        // MathJax 2's `showProcessingMessages: false` and
        // `messageStyle: 'none'` have no MathJax 3 equivalent: version 3 shows
        // no processing messages.
        startup: {
            ready: function () {
                try {
                    window.MathJax.startup.defaultReady();
                    window.MathJax.startup.promise.then(signalEnd, signalEnd);
                } catch (e) {
                    signalEnd();
                    throw e;
                }
            }
        }
    };

    // The MathJax script failed to load (missing file, blocked by policy,
    // network error in a browser).
    document.addEventListener('error', function (event) {
        var target = event.target;
        if (target && target.tagName === 'SCRIPT'
                && /\/tex-mml-chtml\.js(\?|#|$)/.test(target.src || ''))
            signalEnd();
    }, true);

    window.addEventListener('load', function () {
        // If MathJax's startup never installed itself (the script failed or
        // threw while evaluating), nothing else will ever signal.
        var mj = window.MathJax;
        if (!mj || !mj.startup || !mj.startup.promise)
            signalEnd();
        else
            window.setTimeout(signalEnd, END_TIMEOUT_MS);
    });
})();
