import {
  search,
  searchKeymap,
  openSearchPanel,
  closeSearchPanel,
  searchPanelOpen,
  highlightSelectionMatches
} from '@codemirror/search';
import { keymap } from '@codemirror/view';

export function openFindReplace(view) {
  openSearchPanel(view);
  return searchPanelOpen(view.state);
}

export function toggleFindReplace(view) {
  if (searchPanelOpen(view.state)) {
    closeSearchPanel(view);
    return false;
  }
  openSearchPanel(view);
  return true;
}

export function isFindReplaceOpen(state) {
  return searchPanelOpen(state);
}

export function searchExtension() {
  return [
    search({ top: true }),
    highlightSelectionMatches(),
    keymap.of([
      {
        key: 'Mod-f',
        run: view => {
          openSearchPanel(view);
          return true;
        },
        preventDefault: true
      },
      ...searchKeymap
    ])
  ];
}
