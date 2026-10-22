// text-count.js
// MacDown
//
// Collects the raw text segments of the preview document so native code can
// count words and characters with NSString's locale-aware word enumeration.
// Evaluated with -[WKWebView evaluateJavaScript:completionHandler:]; the value
// of this expression is the payload consumed by
// MPPreviewTextCountFromPayload() in MPPreviewTextCount.m.
//
// The traversal mirrors the legacy DOMNode+Text walk exactly:
//
// * SCRIPT, STYLE and HEAD subtrees are skipped for every count.
// * Text and CDATA nodes (types 3 and 4) contribute their nodeValue. Element,
//   document and fragment nodes (1, 9, 11) recurse. Everything else is 0.
// * For words only, a CODE whose parent element is PRE (a code block) is
//   skipped, and any other CODE contributes exactly one word if its contents
//   contain at least one word. Because only native code can segment words,
//   such an inline CODE is emitted as a nested array of its own word items;
//   native code counts it as 1 if the nested items contain any word.
//
// Payload shape:
//   {
//     words: [item, ...],       // item: string | [item, ...] (inline CODE)
//     characters: [string, ...] // every counted text node value
//   }
//
// Words are counted per text node and summed, so node boundaries matter
// ("foo<b>bar</b>" is two words). The text nodes are therefore never joined.
//
// Recursion depth is bounded by DOM depth, which WebKit's HTML parser caps.

(function () {
    'use strict';

    var SKIPPED = { SCRIPT: true, STYLE: true, HEAD: true };

    function isTextNode(node) {
        return node.nodeType === 3 || node.nodeType === 4;
    }

    function isContainerNode(node) {
        return node.nodeType === 1 || node.nodeType === 9
            || node.nodeType === 11;
    }

    function upperTagName(node) {
        return node.nodeType === 1 && typeof node.tagName === 'string'
            ? node.tagName.toUpperCase() : null;
    }

    function collectWords(node, out) {
        if (isTextNode(node)) {
            out.push(String(node.nodeValue));
            return;
        }
        if (!isContainerNode(node))
            return;
        var tag = upperTagName(node);
        if (tag && SKIPPED[tag])
            return;
        if (tag === 'CODE') {
            // The legacy implementation compares the parent's tagName
            // verbatim (not upper-cased); match it.
            var parent = node.parentElement;
            if (parent && parent.tagName === 'PRE')
                return;
            var group = [];
            collectWordChildren(node, group);
            out.push(group);
            return;
        }
        collectWordChildren(node, out);
    }

    function collectWordChildren(node, out) {
        for (var c = node.firstChild; c; c = c.nextSibling)
            collectWords(c, out);
    }

    function collectCharacters(node, out) {
        if (isTextNode(node)) {
            out.push(String(node.nodeValue));
            return;
        }
        if (!isContainerNode(node))
            return;
        var tag = upperTagName(node);
        if (tag && SKIPPED[tag])
            return;
        for (var c = node.firstChild; c; c = c.nextSibling)
            collectCharacters(c, out);
    }

    var words = [];
    var characters = [];
    collectWords(document, words);
    collectCharacters(document, characters);
    return { words: words, characters: characters };
})();
