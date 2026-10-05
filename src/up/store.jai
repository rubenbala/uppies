// The store: everything loaded from the API, plus id lookups.
//
// Transactions are kept newest first. Accounts and categories are never
// reordered or removed once loaded, because transactions refer to them by
// index; refreshes update them in place and append newcomers. `version`
// bumps on every change so derived views (analytics, filtered lists) know
// to recompute.

Store :: struct {
    accounts:     [..] Account;
    categories:   [..] Category;
    tags:         [..] Tag;
    transactions: [..] Transaction;

    txn_lookup:      Table(string, s32);
    category_lookup: Table(string, s32);
    tag_lookup:      Table(string, s32);

    version: u64;
}

store: Store;

store_reset :: (s: *Store) {
    for * s.accounts free_account(it);
    for * s.categories free_category(it);
    for * s.tags free(it.label);
    for * s.transactions free_transaction(it);
    array_reset(*s.accounts);
    array_reset(*s.categories);
    array_reset(*s.tags);
    array_reset(*s.transactions);
    table_reset(*s.txn_lookup);
    table_reset(*s.category_lookup);
    table_reset(*s.tag_lookup);
    s.version += 1;
}

store_find_account :: (s: *Store, id: string) -> s32 {
    if !id.count return -1;
    for s.accounts if it.id == id return cast(s32) it_index;
    return -1;
}

store_find_category :: (s: *Store, id: string) -> s32 {
    if !id.count return -1;
    found, index := table_find(*s.category_lookup, id);
    return ifx found then index else -1;
}

store_find_tag :: (s: *Store, label: string) -> s32 {
    found, index := table_find(*s.tag_lookup, label);
    return ifx found then index else -1;
}

store_find_transaction :: (s: *Store, id: string) -> s32 {
    if !id.count return -1;
    found, index := table_find(*s.txn_lookup, id);
    return ifx found then index else -1;
}

// The tag's index, registering it when new.
store_intern_tag :: (s: *Store, label: string) -> s32 {
    index := store_find_tag(s, label);
    if index >= 0 return index;
    tag := array_add(*s.tags);
    tag.label = copy_string(label);
    index = cast(s32) (s.tags.count - 1);
    table_set(*s.tag_lookup, tag.label, index);
    s.version += 1;
    return index;
}

// Takes ownership of the parsed accounts: known ones are updated in place,
// new ones appended.
store_merge_accounts :: (s: *Store, incoming: [] Account) {
    for incoming {
        index := store_find_account(s, it.id);
        if index >= 0 {
            existing := *s.accounts[index];
            free_account(existing);
            existing.* = it;
        } else {
            array_add(*s.accounts, it);
        }
    }
    s.version += 1;
}

store_merge_categories :: (s: *Store, incoming: [] Category) {
    for incoming {
        index := store_find_category(s, it.id);
        if index >= 0 {
            existing := *s.categories[index];
            parent := existing.parent;
            table_remove(*s.category_lookup, existing.id);
            free_category(existing);
            existing.* = it;
            existing.parent = parent;
            table_set(*s.category_lookup, existing.id, index);
        } else {
            array_add(*s.categories, it);
            table_set(*s.category_lookup, s.categories[s.categories.count - 1].id, cast(s32) (s.categories.count - 1));
        }
    }
    for * s.categories it.parent = store_find_category(s, it.parent_id);
    s.version += 1;
}

// Merges a batch of parsed transactions (taking ownership). Known ids are
// replaced. With `window_since`, every stored transaction created at or
// after it that the batch does not contain is dropped: the batch is the
// complete truth for that window (a declined hold disappears).
store_merge_transactions :: (s: *Store, incoming: [] Transaction, now: float64, window_since: s64 = -1) {
    if window_since >= 0 {
        incoming_ids: Table(string, bool);
        incoming_ids.allocator = temp;
        for incoming table_set(*incoming_ids, it.id, true);
        write := 0;
        for i: 0..s.transactions.count - 1 {
            t := *s.transactions[i];
            if t.created.utc >= window_since && !table_find_pointer(*incoming_ids, t.id) {
                free_transaction(t);
                continue;
            }
            if write != i s.transactions[write] = t.*;
            write += 1;
        }
        s.transactions.count = write;
        rebuild_txn_lookup(s);
    }

    needs_sort := false;
    for incoming {
        index := store_find_transaction(s, it.id);
        if index >= 0 {
            // The lookup's key points into the old storage: rekey it.
            existing := *s.transactions[index];
            arrived := existing.arrived_at;
            table_remove(*s.txn_lookup, existing.id);
            free_transaction(existing);
            existing.* = it;
            existing.arrived_at = arrived;
            table_set(*s.txn_lookup, existing.id, index);
            continue;
        }
        t := it;
        t.arrived_at = now;
        if s.transactions.count && txn_newer(*t, *s.transactions[s.transactions.count - 1]) needs_sort = true;
        array_add(*s.transactions, t);
        table_set(*s.txn_lookup, s.transactions[s.transactions.count - 1].id, cast(s32) (s.transactions.count - 1));
    }
    if needs_sort {
        quick_sort(s.transactions, (a: Transaction, b: Transaction) -> int {
            if a.created.utc != b.created.utc return ifx a.created.utc > b.created.utc then -1 else 1;
            return compare_strings(a.id, b.id);
        });
        rebuild_txn_lookup(s);
    }
    s.version += 1;
}

// Drops one transaction (deleted upstream).
store_remove_transaction :: (s: *Store, index: s32) {
    if index < 0 || index >= s.transactions.count return;
    free_transaction(*s.transactions[index]);
    array_ordered_remove_by_index(*s.transactions, index);
    rebuild_txn_lookup(s);
    s.version += 1;
}

store_set_category :: (s: *Store, txn_index: s32, category: s32) {
    if txn_index < 0 || txn_index >= s.transactions.count return;
    t := *s.transactions[txn_index];
    t.category = cast(s16) category;
    t.parent_category = ifx category >= 0 then cast(s16) s.categories[category].parent else -1;
    s.version += 1;
}

store_add_tag :: (s: *Store, txn_index: s32, tag: s32) {
    if txn_index < 0 || txn_index >= s.transactions.count return;
    t := *s.transactions[txn_index];
    for 0..t.tag_count - 1 if t.tags[it] == tag return;
    if t.tag_count >= MAX_TAGS return;
    t.tags[t.tag_count] = cast(s16) tag;
    t.tag_count += 1;
    s.version += 1;
}

store_remove_tag :: (s: *Store, txn_index: s32, tag: s32) {
    if txn_index < 0 || txn_index >= s.transactions.count return;
    t := *s.transactions[txn_index];
    for 0..t.tag_count - 1 {
        if t.tags[it] != tag continue;
        for j: it..t.tag_count - 2 t.tags[j] = t.tags[j + 1];
        t.tag_count -= 1;
        s.version += 1;
        return;
    }
}

txn_has_tag :: (t: *Transaction, tag: s32) -> bool {
    for 0..t.tag_count - 1 if t.tags[it] == tag return true;
    return false;
}

category_name :: (s: *Store, index: s32) -> string {
    if index < 0 || index >= s.categories.count return "";
    return s.categories[index].name;
}

account_name :: (s: *Store, index: s32) -> string {
    if index < 0 || index >= s.accounts.count return "";
    return s.accounts[index].name;
}

// The parent category of a category index (or itself if it is a parent).
category_root :: (s: *Store, index: s32) -> s32 {
    if index < 0 || index >= s.categories.count return -1;
    p := s.categories[index].parent;
    return ifx p >= 0 then p else index;
}

#scope_file

txn_newer :: inline (a: *Transaction, b: *Transaction) -> bool {
    if a.created.utc != b.created.utc return a.created.utc > b.created.utc;
    return compare_strings(a.id, b.id) < 0;
}

rebuild_txn_lookup :: (s: *Store) {
    table_reset(*s.txn_lookup);
    for s.transactions table_set(*s.txn_lookup, it.id, cast(s32) it_index);
}
