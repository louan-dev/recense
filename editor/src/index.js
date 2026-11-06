import { EditorState } from '@codemirror/state';
import { EditorView, keymap, drawSelection, highlightActiveLine } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { pageMarkersExtension } from './pages.js';
import {
  DEFAULT_FONT_SIZE,
  createThemeCompartments,
  buildThemeExtension,
  buildFontSizeExtension,
  normalizeThemeName,
  normalizeFontSize
} from './theme.js';

export function createEditorExtensions({
  theme = 'dark',
  fontSize = DEFAULT_FONT_SIZE,
  compartments = createThemeCompartments(),
  extraExtensions = []
} = {}) {
  return {
    compartments,
    extensions: [
      history(),
      drawSelection(),
      highlightActiveLine(),
      EditorView.lineWrapping,
      markdown(),
      keymap.of([...defaultKeymap, ...historyKeymap]),
      pageMarkersExtension(),
      compartments.theme.of(buildThemeExtension(theme)),
      compartments.fontSize.of(buildFontSizeExtension(fontSize)),
      ...extraExtensions
    ]
  };
}

export function createEditorState(doc = '', options = {}) {
  const { compartments, extensions } = createEditorExtensions(options);
  const state = EditorState.create({
    doc,
    extensions
  });
  return { state, compartments };
}

export function mountEditor(root = document.body, initialDoc = '') {
  let currentTheme = 'dark';
  let currentFontSize = DEFAULT_FONT_SIZE;

  const shell = document.createElement('div');
  shell.className = 'rc-shell';

  const toolbar = document.createElement('header');
  toolbar.className = 'rc-toolbar';

  const leftGroup = document.createElement('div');
  leftGroup.className = 'rc-toolbar-group';

  const rightGroup = document.createElement('div');
  rightGroup.className = 'rc-toolbar-group';

  const themeBtn = document.createElement('button');
  themeBtn.type = 'button';
  themeBtn.className = 'rc-btn';
  themeBtn.id = 'rc-theme-btn';
  themeBtn.textContent = 'Light';

  rightGroup.appendChild(themeBtn);
  toolbar.append(leftGroup, rightGroup);

  const workspace = document.createElement('div');
  workspace.className = 'rc-workspace';

  const editorHost = document.createElement('main');
  editorHost.className = 'rc-editor-Mount';
  workspace.appendChild(editorHost);

  shell.append(toolbar, workspace);
  root.innerHTML = '';
  root.appendChild(shell);

  const { state, compartments } = createEditorState(initialDoc, {
    theme: currentTheme,
    fontSize: currentFontSize
  });

  const view = new EditorView({
    state,
    parent: editorHost
  });

  function setTheme(mode) {
    currentTheme = normalizeThemeName(mode);
    if (typeof document !== 'undefined' && document.documentElement) {
      document.documentElement.setAttribute('data-theme', currentTheme);
    }
    themeBtn.textContent = currentTheme === 'dark' ? 'Light' : 'Dark';
    view.dispatch({
      effects: compartments.theme.reconfigure(buildThemeExtension(currentTheme))
    });
  }

  function setFontSize(px) {
    currentFontSize = normalizeFontSize(px);
    if (typeof document !== 'undefined' && document.documentElement) {
      document.documentElement.style.setProperty('--rc-font-size', `${currentFontSize}px`);
    }
    view.dispatch({
      effects: compartments.fontSize.reconfigure(buildFontSizeExtension(currentFontSize))
    });
  }

  themeBtn.addEventListener('click', () => {
    setTheme(currentTheme === 'dark' ? 'light' : 'dark');
  });

  setTheme(currentTheme);
  setFontSize(currentFontSize);

  return {
    view,
    setTheme,
    setFontSize,
    getTheme: () => currentTheme,
    getFontSize: () => currentFontSize
  };
}

const DEFAULT_SAMPLE = `Friday, November 6, 2026

§ Negligence

1. Duty of care owed to foreseeable plaintiffs.
   1.1 Majority view (Cardozo): zone of danger.
   1.2 Minority view (Andrews): everyone harmed proximately.

<!-- page -->

Thursday, November 5, 2026

# Contracts Outline

1. Mutual assent requires offer and acceptance.`;

if (typeof window !== 'undefined' && typeof document !== 'undefined') {
  const boot = () => {
    const host = document.getElementById('app') || document.body;
    mountEditor(host, DEFAULT_SAMPLE);
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
}
