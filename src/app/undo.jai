// Undo for category and tag changes.
//
// Every write (sync_set_category, sync_add_tag, sync_remove_tag) is noted
// here as an edit: which transaction, and its category or tag before and
// after. Writes made together, in a batch, are one step; a write on its own
// is a step of its own. Undoing a step writes the reverse of each edit to Up
// through the same calls, so a refused write is put back as any other is.
//
// Only edits that are still in place are reversed: a write that failed was
// already put back, and a transaction changed since (here, in the Up app, or
// by a refresh) is left as it is now. Undo waits while writes are still on
// their way: two workers send them, and the reverse of an edit mustn't
// overtake the edit itself.
//
// Steps are kept for this connection only, the last UNDO_DEPTH of them.

Edit_Kind :: enum u8 { CATEGORY; ADD_TAG; REMOVE_TAG; }

Edit :: struct {
    kind:   Edit_Kind;
    txn_id: string;   // Heap.
    before: string;   // CATEGORY: the category id it had ("" for none).
    after:  string;   // CATEGORY: the category id it was given; tags: the label.
}

Undo_Step :: struct {
    id:    u32;
    label: string;    // Heap: what was done, as a toast says it ("Moved 3 transactions to Groceries.").
    edits: [..] Edit;
}

// One edit of a step that is still in place, and how to reverse it.
Undo_Reversal :: struct {
    index:    s32;    // Transaction.
    kind:     Edit_Kind;
    category: s32;    // CATEGORY: what to put back (-1: none).
    tag:      s32;    // REMOVE_TAG: the tag to take off again.
    label:    string; // ADD_TAG: the tag to put back on.
}

UNDO_DEPTH :: 20;

Undo_State :: struct {
    steps:   [..] Undo_Step;   // Oldest first.
    next_id: u32;
    open:    u32;              // The step a batch is filling, 0 when none.
    undoing: bool;             // Writes now are an undo's: not noted.
}

undo: Undo_State;

// Notes one write. Outside a batch it is a step of its own.
undo_note :: (kind: Edit_Kind, txn_id: string, before: string, after: string) {
    if undo.undoing return;
    step := find_step(undo.open);
    if !step {
        step = new_step();
        step.label = copy_string(single_label(kind, txn_id, after));
    }
    edit := array_add(*step.edits);
    edit.kind = kind;
    edit.txn_id = copy_string(txn_id);
    edit.before = copy_string(before);
    edit.after = copy_string(after);
}

// Writes until undo_end are one step (sync_batch_begin and _end call these).
undo_begin :: () {
    if undo.undoing return;
    undo.open = new_step().id;
}

// Closes the step with what it did; returns its id (0 when there is nothing
// in it to undo).
undo_end :: (label: string) -> u32 {
    step, index := find_step(undo.open);
    undo.open = 0;
    if !step return 0;
    if !step.edits.count { drop_step(index); return 0; }
    set_string(*step.label, label);
    return step.id;
}

// The step ⌘Z would undo, or 0.
undo_latest :: () -> u32 {
    if !undo.steps.count return 0;
    return undo.steps[undo.steps.count - 1].id;
}

// Undoes the latest step, or the step `id` when it is the latest (a toast's
// Undo button, which goes stale once anything else is changed).
undo_last :: (id: u32 = 0) {
    if !undo.steps.count { app_toast(.INFO, "Nothing to undo."); return; }
    if id && id != undo_latest() return;
    if sync.pending_writes > 0 { app_toast(.INFO, "Still saving the last change. Try again in a moment."); return; }
    index := undo.steps.count - 1;
    step := *undo.steps[index];
    plan := undo_plan(step);
    done := tprint("Undid: %", lower_first(step.label));
    if !plan.count {
        app_toast(.INFO, "Nothing to undo there: those transactions have changed since.");
    } else {
        undo.undoing = true;
        sync_batch_begin();
        for plan {
            if it.kind == {
                case .CATEGORY;   sync_set_category(it.index, it.category);
                case .ADD_TAG;    sync_remove_tag(it.index, it.tag);
                case .REMOVE_TAG; sync_add_tag(it.index, it.label);
            }
        }
        sync_batch_end(done, "Not all of it undone");
        undo.undoing = false;
    }
    drop_step(index);
}

// The edits of a step still in place, newest first, with what reverses each
// (temporary storage).
undo_plan :: (step: *Undo_Step) -> [] Undo_Reversal {
    plan: [..] Undo_Reversal;
    plan.allocator = temp;
    for < step.edits {
        index := store_find_transaction(*store, it.txn_id);
        if index < 0 continue;   // Gone from Up.
        t := *store.transactions[index];
        r := Undo_Reversal.{index = index, kind = it.kind};
        if it.kind == {
            case .CATEGORY;
                after := store_find_category(*store, it.after);
                if t.category != after continue;
                r.category = store_find_category(*store, it.before);
                if r.category == after continue;
            case .ADD_TAG;
                r.tag = store_find_tag(*store, it.after);
                if r.tag < 0 || !txn_has_tag(t, r.tag) continue;
            case .REMOVE_TAG;
                tag := store_find_tag(*store, it.after);
                if (tag >= 0 && txn_has_tag(t, tag)) || t.tag_count >= MAX_TAGS continue;
                r.label = it.after;
        }
        array_add(*plan, r);
    }
    return plan;
}

// Forgets every step: the transactions they name are gone (a new token,
// sample data, a reload).
undo_clear :: () {
    while undo.steps.count drop_step(undo.steps.count - 1);
    undo.open = 0;
}

#scope_file

new_step :: () -> *Undo_Step {
    if undo.steps.count >= UNDO_DEPTH {
        // The oldest goes, unless a batch is still filling it.
        oldest := 0;
        if undo.steps[0].id == undo.open oldest = 1;
        if oldest < undo.steps.count drop_step(oldest);
    }
    undo.next_id += 1;
    step := array_add(*undo.steps);
    step.id = undo.next_id;
    return step;
}

find_step :: (id: u32) -> *Undo_Step, int {
    if !id return null, -1;
    for * undo.steps if it.id == id return it, it_index;
    return null, -1;
}

drop_step :: (index: int) {
    step := *undo.steps[index];
    for step.edits { free(it.txn_id); free(it.before); free(it.after); }
    array_free(step.edits);
    free(step.label);
    array_ordered_remove_by_index(*undo.steps, index);
}

// What a write on its own did: "Moved Netflix to Groceries.", "Tagged Netflix \"Work\"."
single_label :: (kind: Edit_Kind, txn_id: string, after: string) -> string {
    index := store_find_transaction(*store, txn_id);
    name := ifx index >= 0 then store.transactions[index].description else "a transaction";
    if kind == {
        case .CATEGORY;
            category := store_find_category(*store, after);
            if category < 0 return tprint("Took % out of its category.", name);
            return tprint("Moved % to %.", name, store.categories[category].name);
        case .ADD_TAG;
            return tprint("Tagged % \"%\".", name, after);
    }
    return tprint("Removed \"%\" from %.", after, name);
}

lower_first :: (text: string) -> string {
    if !text.count || text[0] < #char "A" || text[0] > #char "Z" return text;
    result := copy_string(text,, temp);
    result[0] += #char "a" - #char "A";
    return result;
}
