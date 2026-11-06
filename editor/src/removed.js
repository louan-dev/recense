import { Annotation, EditorState, StateField } from '@codemirror/state';
import { externalSetTextAnnotation } from './bridge.js';

const CONTEXT_RADIUS = 80;

const recordedDeletionsAnnotation = Annotation.define();

/**
 * StateField storing the chronological deletion records for the "Farewell" episode (D32).
 */
export const removedStateField = StateField.define({
  create() {
    return [];
  },
  update(records, tr) {
    const added = tr.annotation(recordedDeletionsAnnotation);
    if (!added || added.length === 0) return records;
    return [...records, ...added];
  }
});

/**
 * Transaction filter that captures every user deletion with its timestamp,
 * offsets, and surrounding context before the text disappears.
 * Ignores programmatic host updates (`externalSetTextAnnotation`).
 */
export const removedTransactionFilter = EditorState.transactionFilter.of(tr => {
  if (!tr.docChanged || tr.annotation(externalSetTextAnnotation)) {
    return tr;
  }

  const entries = [];
  const now = Date.now();
  const startDoc = tr.startState.doc;

  tr.changes.iterChanges((fromA, toA) => {
    if (toA <= fromA) return;
    const text = startDoc.sliceString(fromA, toA);
    const before = startDoc.sliceString(Math.max(0, fromA - CONTEXT_RADIUS), fromA);
    const after = startDoc.sliceString(toA, Math.min(startDoc.length, toA + CONTEXT_RADIUS));
    entries.push({
      text,
      from: fromA,
      to: toA,
      time: now,
      before,
      after,
      context: `${before}${after}`
    });
  });

  if (entries.length === 0) {
    return tr;
  }

  return [tr, { annotations: recordedDeletionsAnnotation.of(entries) }];
});

export function removedRecordExtension() {
  return [removedStateField, removedTransactionFilter];
}

export function getRemoved(state) {
  if (!state || typeof state.field !== 'function') return [];
  return state.field(removedStateField, false) || [];
}
