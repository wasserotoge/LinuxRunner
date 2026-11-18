/**
 * xterm-term-bridge.js — xterm.js terminal bridge for ios-linuxkit.
 *
 * Drop-in alternative to term.js (Ghostty). Uses the same native bridge API
 * (window.exports / webkit.messageHandlers) so the Obj-C host code doesn't
 * need changes — only the HTML entry point differs (xterm-term.html vs term.html).
 *
 * Build switch: in Terminal.m, load xterm-term.html instead of term.html to use
 * the xterm.js renderer instead of Ghostty WebGL/Canvas2D.
 */

(async () => {
    'use strict';

    window.exports = {
        write() {},
        getSize: () => [0, 0],
        copy: () => false,
        setFocused() {},
        scrollToBottom() {},
        newScrollTop() {},
        updateStyle() {},
        getCharacterSize: () => [0, 0],
        clearScrollback() {},
        setUserGesture() {},
        setAccessibilityEnabled() {},
    };

    const terminalElement = document.getElementById('terminal');
    const { Terminal, FitAddon, WebLinksAddon, LigaturesAddon } = window.xtermModules || {};
    const { CanvasAddon } = window.CanvasAddon || {};
    if (!Terminal || !FitAddon || !WebLinksAddon || !LigaturesAddon) {
        window.__terminalBootstrapLog?.('terminal xterm modules were not loaded');
        return;
    }
    if (!CanvasAddon) {
        window.__terminalBootstrapLog?.('terminal xterm canvas addon was not loaded');
        return;
    }

    const ansiColorNames = [
        'black',
        'red',
        'green',
        'yellow',
        'blue',
        'magenta',
        'cyan',
        'white',
        'brightBlack',
        'brightRed',
        'brightGreen',
        'brightYellow',
        'brightBlue',
        'brightMagenta',
        'brightCyan',
        'brightWhite',
    ];

    // ── Native bridge (same as term.js) ──────────────────────────────────────
    const native = new Proxy({}, {
        get(_, prop) {
            return (...args) => {
                if (!window.webkit?.messageHandlers?.[prop])
                    return;
                let body = null;
                if (args.length == 1)
                    body = args[0];
                else if (args.length > 1)
                    body = args;
                window.webkit.messageHandlers[prop].postMessage(body);
            };
        }
    });

    // ── Style state ──────────────────────────────────────────────────────────
    let styleState = {
        foregroundColor: '#d4d4d4',
        backgroundColor: '#1e1e1e',
        cursorColor: undefined,
        fontSize: 12,
        fontFamily: '"JetBrainsMono Nerd Font Mono", "FiraCode Nerd Font Mono", ui-monospace, "SFMono-Regular", Menlo, Monaco, monospace',
        colorPaletteOverrides: undefined,
        blinkCursor: false,
        cursorShape: 'BLOCK',
    };
    styleState = {...styleState, ...normalizeStyleUpdate(window.__terminalInitialStyle)};
    applyDocumentStyle(styleState);
    await loadConfiguredFont(styleState);

    let resizeFrame = null;
    let pendingScrollSync = false;
    let lastNativeScrollHeight;
    let lastNativeScrollTop;
    let nativeScrollRequest = null;
    let oldProps = {};
    let xtermAppActive = null;
    // Cells the current selection gesture started from, end exclusive:
    // {startCol, startRow, endCol, endRow, word}. Rows are buffer rows.
    let selectionAnchor = null;
    let pendingSelectionGeometry = false;

    // ── Terminal setup ────────────────────────────────────────────────────────
    const term = new Terminal({
        cols: 80,
        rows: 24,
        fontSize: styleState.fontSize,
        fontFamily: styleState.fontFamily,
        theme: {
            foreground: styleState.foregroundColor,
            background: styleState.backgroundColor,
            cursor: styleState.cursorColor || styleState.foregroundColor,
            cursorAccent: styleState.backgroundColor,
        },
        cursorBlink: styleState.blinkCursor,
        cursorStyle: cursorStyleForXterm(styleState.cursorShape),
        allowTransparency: true,
        scrollback: 10000,
        convertEol: false,
        disableStdin: true,  // iOS handles text input natively
        allowProposedApi: true,
        overviewRuler: {width: 0},
        smoothScrollDuration: 0,
        windowsMode: false,
    });

    const fitAddon = new FitAddon();
    term.loadAddon(new CanvasAddon());
    term.loadAddon(fitAddon);
    term.loadAddon(new WebLinksAddon());

    term.onData((data) => {
        native.sendInput(data);
        syncApplicationCursor();
    });
    // X10-encoded mouse reports are bytes, not UTF-8 text.
    term.onBinary((data) => native.sendBinary(data));
    term.onResize(() => {
        native.resize();
        scheduleScrollSync();
        scheduleSelectionGeometry();
    });
    term.onScroll(() => {
        scheduleScrollSync();
        scheduleSelectionGeometry();
    });
    term.onCursorMove(syncApplicationCursor);
    term.onSelectionChange(() => {
        native.selectionChanged(term.getSelection());
        scheduleSelectionGeometry();
    });
    term.buffer.onBufferChange((buffer) => {
        native.bufferType(buffer.type);
        scheduleSelectionGeometry();
    });

    term.open(terminalElement);
    installNativeFocusAdapter();
    installLigatures();
    disableWebTextInput();
    installFocusBridge();
    fitAddon.fit();
    syncApplicationCursor();
    scheduleScrollSync();

    // ── Resize handling ──────────────────────────────────────────────────────
    function fitTerminal() {
        if (resizeFrame !== null)
            return;
        resizeFrame = requestAnimationFrame(() => {
            resizeFrame = null;
            fitAddon.fit();
            // The glyph atlas is built for the pixel density seen when the
            // terminal opened (1x while the web view was still offscreen);
            // WKWebView sends no DPR change, so rebuild it when the density
            // differs from the one the atlas was drawn at.
            if (window.devicePixelRatio !== fitTerminal.atlasRatio) {
                fitTerminal.atlasRatio = window.devicePixelRatio;
                term.clearTextureAtlas?.();
                term.refresh(0, term.rows - 1);
            }
            native.resize();
            scheduleScrollSync();
            scheduleSelectionGeometry();
        });
    }

    const ro = new ResizeObserver(() => fitTerminal());
    ro.observe(terminalElement);

    // ── Exports (native → JS) ────────────────────────────────────────────────
    function latin1StringToBytes(str) {
        const bytes = new Uint8Array(str.length);
        for (let i = 0; i < str.length; i++) {
            bytes[i] = str.charCodeAt(i) & 0xff;
        }
        return bytes;
    }

    window.exports = {
        write(data) {
            const bytes = typeof data === 'string' ? latin1StringToBytes(data) : new Uint8Array(data);
            term.write(bytes, scheduleScrollSync);
            if (bytes.includes(0x1b))
                syncApplicationCursor();
        },
        getSize() {
            return [term.cols, term.rows];
        },
        copy() {
            return term.getSelection();
        },
        // Long press: select the word under the point. Returns whether a word
        // was found; on blank cells the gesture can still drag out a range.
        selectWordAt(x, y) {
            const cell = selectionCell(x, y);
            if (!cell) {
                selectionAnchor = null;
                return false;
            }
            const word = wordRange(cell.row, cell.col);
            if (!word) {
                selectionAnchor = {startCol: cell.col, startRow: cell.row, endCol: cell.col + 1, endRow: cell.row, word: false};
                term.clearSelection();
                return false;
            }
            selectionAnchor = {...word, word: true};
            selectRange(word.startCol, word.startRow, word.endCol, word.endRow);
            return true;
        },
        // Pointer drag: character selection from the press point.
        beginSelection(x, y) {
            const cell = selectionCell(x, y);
            selectionAnchor = cell ? {startCol: cell.col, startRow: cell.row, endCol: cell.col + 1, endRow: cell.row, word: false} : null;
            term.clearSelection();
        },
        extendSelection(x, y) {
            const cell = selectionCell(x, y);
            if (!selectionAnchor || !cell)
                return;
            const cols = term.cols;
            const anchorStart = selectionAnchor.startRow * cols + selectionAnchor.startCol;
            const anchorEnd = selectionAnchor.endRow * cols + selectionAnchor.endCol;
            const point = cell.row * cols + cell.col;
            if (point >= anchorEnd)
                selectLinear(anchorStart, point + 1);
            else if (point < anchorStart)
                selectLinear(point, anchorEnd);
            else if (selectionAnchor.word)
                selectLinear(anchorStart, anchorEnd);
            else
                term.clearSelection();
        },
        // Selection handles: move one end of the selection to the cell
        // boundary nearest the point, keeping at least one cell selected.
        dragSelectionHandle(which, x, y) {
            const pos = term.getSelectionPosition();
            const boundary = selectionBoundary(x, y);
            if (!pos || !boundary)
                return;
            const cols = term.cols;
            const start = pos.start.y * cols + pos.start.x;
            const end = pos.end.y * cols + pos.end.x;
            const point = boundary.row * cols + boundary.col;
            selectionAnchor = null;
            if (which === 'start')
                selectLinear(Math.min(point, end - 1), end);
            else
                selectLinear(start, Math.max(point, start + 1));
        },
        selectionGeometry() {
            return selectionGeometry();
        },
        bufferType() {
            return term.buffer.active.type;
        },
        // Touch scrolling where there is no scrollback (the alternate screen):
        // one wheel notch per line, so xterm reports wheel events to
        // mouse-aware programs and sends arrow keys to the others.
        scrollLines(lines, x, y) {
            if (!Number.isFinite(lines) || !Number.isFinite(x) || !Number.isFinite(y))
                return;
            const count = Math.min(Math.abs(Math.trunc(lines)), 200);
            const target = terminalElement.querySelector('.xterm-screen') || term.element;
            if (!count || !target)
                return;
            withStdin(() => {
                for (let i = 0; i < count; i++) {
                    target.dispatchEvent(new WheelEvent('wheel', {
                        deltaY: lines < 0 ? -1 : 1,
                        deltaMode: WheelEvent.DOM_DELTA_LINE,
                        clientX: x,
                        clientY: y,
                        bubbles: true,
                        cancelable: true,
                    }));
                }
            });
        },
        selectAll() { selectionAnchor = null; term.selectAll(); },
        clearSelection() { selectionAnchor = null; term.clearSelection(); },
        setFocused(focused) {
            terminalElement.classList.toggle('terminal-focused', !!focused);
            setXtermAppActive(!!focused);
        },
        scrollToBottom() {
            term.scrollToBottom();
            scheduleScrollSync();
        },
        newScrollTop(top) {
            if (!Number.isFinite(top))
                return;
            const cellHeight = getCellSize().height;
            if (!cellHeight)
                return;
            const buffer = term.buffer.active;
            const line = Math.max(0, Math.min(buffer.baseY, Math.round(top / cellHeight)));
            // UIKit owns fractional offsets and momentum. Do not snap its
            // offset back to the rounded row when acknowledging this request.
            nativeScrollRequest = {buffer, line, cellHeight};
            term.scrollToLine(line);
            scheduleScrollSync();
        },
        async updateStyle(newStyle) {
            styleState = {...styleState, ...normalizeStyleUpdate(newStyle)};
            applyDocumentStyle(styleState);
            await loadConfiguredFont(styleState);

            if (term.options.fontSize !== styleState.fontSize)
                term.options.fontSize = styleState.fontSize;
            if (term.options.fontFamily !== styleState.fontFamily)
                term.options.fontFamily = styleState.fontFamily;
            term.options.cursorBlink = !!styleState.blinkCursor;
            term.options.cursorStyle = cursorStyleForXterm(styleState.cursorShape);
            term.options.theme = themeForXterm(styleState);

            fitTerminal();
            term.refresh(0, term.rows - 1);
            scheduleScrollSync();
        },
        getCharacterSize() {
            const size = getCellSize();
            return [size.width || 0, size.height || 0];
        },
        clearScrollback() {
            term.clear();
            term.scrollToBottom();
            scheduleScrollSync();
        },
        setUserGesture() {},
        setAccessibilityEnabled() {},
    };

    // ── Signal ready ─────────────────────────────────────────────────────────
    setXtermAppActive(true);
    fitTerminal();
    native.load();
    native.syncFocus();
    native.bufferType(term.buffer.active.type);

    function disableWebTextInput() {
        if (!term.textarea)
            return;
        term.textarea.readOnly = true;
        term.textarea.tabIndex = -1;
        term.textarea.autocapitalize = 'off';
        term.textarea.autocomplete = 'off';
        term.textarea.autocorrect = 'off';
        term.textarea.spellcheck = false;
    }

    function selectionCell(x, y) {
        const screen = terminalElement.querySelector('.xterm-screen');
        const cell = getCellSize();
        if (!screen || !cell.width || !cell.height || !Number.isFinite(x) || !Number.isFinite(y))
            return null;
        const rect = screen.getBoundingClientRect();
        return {
            col: Math.max(0, Math.min(term.cols - 1, Math.floor((x - rect.left) / cell.width))),
            row: term.buffer.active.viewportY + Math.max(0, Math.min(term.rows - 1, Math.floor((y - rect.top) / cell.height))),
        };
    }

    // The cell boundary nearest to x on the row under y; col runs 0...cols.
    function selectionBoundary(x, y) {
        const screen = terminalElement.querySelector('.xterm-screen');
        const cell = getCellSize();
        if (!screen || !cell.width || !cell.height || !Number.isFinite(x) || !Number.isFinite(y))
            return null;
        const rect = screen.getBoundingClientRect();
        return {
            col: Math.max(0, Math.min(term.cols, Math.round((x - rect.left) / cell.width))),
            row: term.buffer.active.viewportY + Math.max(0, Math.min(term.rows - 1, Math.floor((y - rect.top) / cell.height))),
        };
    }

    // Select cells [start, end) in row-major cell order.
    function selectLinear(start, end) {
        const cols = term.cols;
        if (!cols || !(end > start)) {
            term.clearSelection();
            return;
        }
        term.select(start % cols, Math.floor(start / cols), end - start);
    }

    function selectRange(startCol, startRow, endCol, endRow) {
        selectLinear(startRow * term.cols + startCol, endRow * term.cols + endCol);
    }

    function isWordCell(line, col) {
        if (col < 0 || col >= term.cols)
            return false;
        const cell = line.getCell(col);
        if (!cell)
            return false;
        // The second half of a wide character belongs to the first half.
        if (cell.getWidth() === 0)
            return col > 0 && isWordCell(line, col - 1);
        const chars = cell.getChars();
        if (!chars || /^\s+$/.test(chars))
            return false;
        return !String(term.options.wordSeparator ?? ' ()[]{}\',"`').includes(chars);
    }

    // Same word rule as xterm's double-click selection, within one row.
    function wordRange(row, col) {
        const line = term.buffer.active.getLine(row);
        if (!line || !isWordCell(line, col))
            return null;
        let start = col;
        while (start > 0 && isWordCell(line, start - 1))
            start--;
        let end = col + 1;
        while (end < term.cols && isWordCell(line, end))
            end++;
        return {startCol: start, startRow: row, endCol: end, endRow: row};
    }

    // Where the selection ends are on screen, in page (web view) coordinates.
    // start/end are the top of the first and last selected rows at the
    // selection's left and right edges; bounds encloses the visible part.
    function selectionGeometry() {
        const pos = term.hasSelection() ? term.getSelectionPosition() : undefined;
        const screen = terminalElement.querySelector('.xterm-screen');
        const cell = getCellSize();
        if (!pos || !screen || !cell.width || !cell.height)
            return null;
        const rect = screen.getBoundingClientRect();
        const top = term.buffer.active.viewportY;
        let endCol = pos.end.x;
        let endRow = pos.end.y;
        if (endCol <= 0 && endRow > pos.start.y) {
            endRow -= 1;
            endCol = term.cols;
        }
        const rowTop = (row) => rect.top + (row - top) * cell.height;
        const onScreen = (row) => row >= top && row < top + term.rows;
        const firstVisible = Math.max(pos.start.y, top);
        const lastVisible = Math.min(endRow, top + term.rows - 1);
        let bounds = null;
        if (firstVisible <= lastVisible) {
            const singleRow = pos.start.y === endRow;
            const left = singleRow ? rect.left + pos.start.x * cell.width : rect.left;
            const right = singleRow ? rect.left + endCol * cell.width : rect.left + term.cols * cell.width;
            bounds = {
                x: left,
                y: rowTop(firstVisible),
                width: Math.max(right - left, 1),
                height: (lastVisible - firstVisible + 1) * cell.height,
            };
        }
        return {
            start: {x: rect.left + pos.start.x * cell.width, y: rowTop(pos.start.y), visible: onScreen(pos.start.y)},
            end: {x: rect.left + endCol * cell.width, y: rowTop(endRow), visible: onScreen(endRow)},
            lineHeight: cell.height,
            bounds,
        };
    }

    function scheduleSelectionGeometry() {
        if (pendingSelectionGeometry)
            return;
        pendingSelectionGeometry = true;
        requestAnimationFrame(() => {
            pendingSelectionGeometry = false;
            native.selectionGeometry(selectionGeometry());
        });
    }

    // xterm drops everything it would send while stdin is disabled, which
    // includes wheel-generated arrow keys and mouse reports.
    function withStdin(action) {
        const disabled = term.options.disableStdin;
        if (disabled)
            term.options.disableStdin = false;
        try {
            action();
        } finally {
            if (disabled) {
                term.options.disableStdin = true;
                disableWebTextInput();
            }
        }
    }

    function installFocusBridge() {
        // TerminalView handles touches natively (focus, scrolling, selection)
        // and keeps them from reaching the page; this only stops WebKit's own
        // touch behaviour should one arrive anyway.
        terminalElement.addEventListener('touchstart', (event) => {
            event.preventDefault();
        }, {capture: true, passive: false});
        terminalElement.addEventListener('mousedown', (event) => {
            event.preventDefault();
            if (!term.hasSelection())
                native.focus();
        }, {capture: true});
        terminalElement.addEventListener('focus', () => native.syncFocus());
        terminalElement.addEventListener('blur', () => native.syncFocus());
    }

    function installLigatures() {
        try {
            term.loadAddon(new LigaturesAddon());
        } catch (error) {
            native.log(`terminal ligatures addon failed: ${error?.stack || error}`);
        }
    }

    function installNativeFocusAdapter() {
        const browserService = term._core?._coreBrowserService;
        if (!browserService)
            return;
        try {
            Object.defineProperty(browserService, 'isFocused', {
                configurable: true,
                get: () => !!xtermAppActive,
            });
        } catch (error) {
            native.log(`terminal focus adapter failed: ${error?.stack || error}`);
        }
    }

    function setXtermAppActive(active) {
        if (xtermAppActive === active) {
            if (active)
                ensureCursorVisible();
            return;
        }
        xtermAppActive = active;

        const core = term._core;
        try {
            if (core?.element)
                core.element.classList.toggle('focus', active);
            if (active) {
                core?._renderService?.handleFocus?.();
                ensureCursorVisible();
            } else {
                core?._renderService?.handleBlur?.();
            }
        } catch (error) {
            native.log(`terminal focus sync failed: ${error?.stack || error}`);
        }
    }

    function ensureCursorVisible() {
        const coreService = term._core?.coreService;
        if (coreService)
            coreService.isCursorInitialized = true;
        term.refresh(term.buffer.active.cursorY, term.buffer.active.cursorY);
    }

    function scheduleScrollSync() {
        if (pendingScrollSync)
            return;
        pendingScrollSync = true;
        requestAnimationFrame(() => {
            pendingScrollSync = false;
            syncScroll();
        });
    }

    function syncScroll() {
        const cellHeight = getCellSize().height;
        if (!cellHeight)
            return;
        const buffer = term.buffer.active;
        // Fit rounds rows down; the unused fraction still belongs to UIKit's
        // viewport. Its maximum offset must equal baseY * cellHeight exactly.
        const scrollHeight = buffer.baseY * cellHeight + terminalElement.clientHeight;
        const scrollTop = buffer.viewportY * cellHeight;

        if (scrollHeight !== lastNativeScrollHeight) {
            native.newScrollHeight(scrollHeight);
            lastNativeScrollHeight = scrollHeight;
        }
        const acknowledgesNativeScroll = nativeScrollRequest?.buffer === buffer &&
            nativeScrollRequest.line === buffer.viewportY &&
            nativeScrollRequest.cellHeight === cellHeight;
        nativeScrollRequest = null;
        if (!acknowledgesNativeScroll && scrollTop !== lastNativeScrollTop) {
            native.newScrollTop(scrollTop);
        }
        lastNativeScrollTop = scrollTop;
    }

    function syncApplicationCursor() {
        syncProp('applicationCursor', !!term.modes?.applicationCursorKeysMode);
        syncProp('bracketedPaste', !!term.modes?.bracketedPasteMode);
    }

    function syncProp(name, value) {
        if (oldProps[name] !== value)
            native.propUpdate(name, value);
        oldProps[name] = value;
    }

    function getCellSize() {
        const dims = term._core?._renderService?.dimensions;
        return {
            width: dims?.css?.cell?.width || 0,
            height: dims?.css?.cell?.height || 0,
        };
    }

    function normalizeStyleUpdate(nextStyle) {
        const style = {...(nextStyle || {})};
        if (!Array.isArray(style.colorPaletteOverrides))
            style.colorPaletteOverrides = undefined;
        return style;
    }

    function applyDocumentStyle(style) {
        if (style.backgroundColor)
            document.documentElement.style.setProperty('--terminal-background', style.backgroundColor);
        if (style.foregroundColor)
            document.documentElement.style.setProperty('--terminal-foreground', style.foregroundColor);
    }

    async function loadConfiguredFont(style) {
        if (!document.fonts?.load)
            return;
        const family = firstFontFamily(style.fontFamily);
        if (!family)
            return;
        try {
            await Promise.all([
                document.fonts.load(`${style.fontSize}px ${quoteCssFontFamily(family)}`),
                document.fonts.load(`700 ${style.fontSize}px ${quoteCssFontFamily(family)}`),
            ]);
            await document.fonts.ready;
        } catch (error) {
            native.log(`terminal font load failed: ${error}`);
        }
    }

    function firstFontFamily(familyList) {
        const trimmed = String(familyList || '').trim();
        if (!trimmed)
            return '';
        const match = trimmed.match(/^(['"])(.*?)\1/);
        if (match)
            return match[2];
        return trimmed.split(',')[0].trim();
    }

    function quoteCssFontFamily(family) {
        const trimmed = String(family || '').trim();
        if (!trimmed || trimmed.startsWith('"') || trimmed.startsWith("'"))
            return trimmed;
        if (/^[a-zA-Z_-][a-zA-Z0-9_-]*$/.test(trimmed))
            return trimmed;
        return `"${trimmed.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
    }

    function cursorStyleForXterm(cursorShape) {
        switch (cursorShape) {
            case 'BEAM':
            case 'bar':
                return 'bar';
            case 'UNDERLINE':
            case 'underline':
                return 'underline';
            case 'BLOCK':
            case 'block':
            default:
                return 'block';
        }
    }

    function themeForXterm(style) {
        const theme = {
            foreground: style.foregroundColor,
            background: style.backgroundColor,
            cursor: style.cursorColor || style.foregroundColor,
            cursorAccent: style.backgroundColor,
            selectionBackground: style.foregroundColor,
            selectionForeground: style.backgroundColor,
        };
        if (Array.isArray(style.colorPaletteOverrides)) {
            for (let i = 0; i < Math.min(ansiColorNames.length, style.colorPaletteOverrides.length); i++)
                theme[ansiColorNames[i]] = style.colorPaletteOverrides[i];
        }
        return theme;
    }

})();
