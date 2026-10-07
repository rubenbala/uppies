// A transaction as a PDF: everything Up says about it, laid out like the
// inspector (amount and when, then category and tags, how it was paid, any
// message or note, and the record: raw text, timestamps, the id). Money in
// is marked "+"; money out has no sign, here and on statements.
//
// Several transactions print two ways: each like that, starting on a page of
// its own, or a statement listing them all (date, description, amount) under
// what they add up to. Both put them oldest first.

// Asks where to save it and saves it.
save_transaction_pdf :: (index: s32) {
    if index < 0 || index >= store.transactions.count return;
    t := *store.transactions[index];
    d := civil_from_days(t.day);
    name := print_file_name("Transaction", t.description, tprint("%-%-%", d.year, pad2(d.month), pad2(d.day)));
    print_save(print_transaction_pdf(index), name);
}

// The PDF's bytes (temporary storage).
print_transaction_pdf :: (index: s32) -> string {
    doc: Print_Doc;
    print_begin(*doc, "Transaction", store.transactions[index].description);
    print_transaction(*doc, index);
    return print_finish(*doc);
}

// Several transactions, each as print_transaction_pdf has it, starting on a
// page of its own. Asks where to save it and saves it.
save_transactions_pdf :: (indices: [] s32) {
    if !indices.count return;
    print_save(print_transactions_pdf(indices), print_file_name("Transactions", date_range_name(indices)));
}

print_transactions_pdf :: (indices: [] s32) -> string {
    sorted := oldest_first(indices);
    doc: Print_Doc;
    print_begin(*doc, "Transaction", format_count(sorted.count, "transaction", "transactions"));
    for sorted {
        if it_index print_new_page(*doc);
        print_transaction(*doc, it);
    }
    return print_finish(*doc);
}

// Several transactions as a statement: what they add up to, then a line for
// each with its date, description and amount, and the total. Money in is
// marked "+"; money out has no sign. Asks where to
// save it and saves it.
save_statement_pdf :: (indices: [] s32) {
    if !indices.count return;
    print_save(print_statement_pdf(indices), print_file_name("Statement", date_range_name(indices)));
}

print_statement_pdf :: (indices: [] s32) -> string {
    sorted := oldest_first(indices);
    money_in, money_out: s64;
    held := 0;
    accounts: [..] s32;
    accounts.allocator = temp;
    for sorted {
        t := *store.transactions[it];
        if t.amount > 0 money_in += t.amount; else money_out -= t.amount;
        if t.status == .HELD held += 1;
        array_add_if_unique(*accounts, t.account);
    }
    net := money_in - money_out;
    first_day := store.transactions[sorted[0]].day;
    last_day  := store.transactions[sorted[sorted.count - 1]].day;

    doc: Print_Doc;
    title := format_count(sorted.count, "transaction", "transactions");
    print_begin(*doc, "Statement", title);
    print_title(*doc, title);
    print_amount(*doc, format_money(net, .POSITIVE), ifx net > 0 then PRINT_POSITIVE else PRINT_TEXT);
    print_caption(*doc, ifx first_day == last_day then format_date_long(first_day) else tprint("% to %", format_date_long(first_day), format_date_long(last_day)));

    print_section(*doc, "Summary");
    print_field(*doc, "Money in", ifx money_in then format_money(money_in) else "—", color = ifx money_in then PRINT_POSITIVE else 0);
    print_field(*doc, "Money out", ifx money_out then format_money(money_out) else "—");
    print_field(*doc, "Net", format_money(net, .POSITIVE));
    names: [..] string;
    names.allocator = temp;
    for accounts array_add(*names, account_name(*store, it));
    print_field(*doc, ifx accounts.count == 1 then "Account" else "Accounts", join(..names, separator = ", ",, temp));
    if held print_field(*doc, "Held", tprint("% waiting to settle", held), color = PRINT_HELD);

    print_section(*doc, "Transactions");
    print_table_begin(*doc, .[
        .{"Date", 82, false},
        .{"Description", 0, false},
        .{"Amount", 92, true},
    ]);
    for sorted {
        t := *store.transactions[it];
        color := ifx t.status == .HELD then PRINT_HELD else ifx t.amount > 0 then PRINT_POSITIVE else 0;
        print_table_row(*doc, .[format_date(t.day), t.description, format_money(t.amount, .POSITIVE)], .[0, 0, color]);
    }
    print_table_row(*doc, .["", "Total", format_money(net, .POSITIVE)], total = true);
    print_table_end(*doc);
    if held print_note(*doc, "Amounts in amber are held: waiting to settle, and may change when they do.");

    return print_finish(*doc);
}

#scope_file

// The transaction's pages, from where the document is up to.
print_transaction :: (doc: *Print_Doc, index: s32) {
    t := *store.transactions[index];
    print_title(doc, t.description);
    print_amount(doc, format_money(t.amount, .POSITIVE), ifx t.amount > 0 then PRINT_POSITIVE else PRINT_TEXT);
    print_caption(doc, tprint("% at %", format_date_long(t.day), format_time(t.created)));

    print_section(doc, "Summary");
    print_field(doc, "Account", account_name(*store, t.account));
    if is_transfer(t) print_field(doc, ifx t.amount < 0 then "Transferred to" else "Transferred from", account_name(*store, t.transfer_account));
    category := "";
    if !t.categorizable category = "Not categorisable (transfers, interest and payments to people aren't)";
    else if t.category < 0 category = "Uncategorised";
    else {
        root := category_root(*store, t.category);
        category = store.categories[t.category].name;
        if root != t.category category = tprint("% › %", store.categories[root].name, category);
    }
    print_field(doc, "Category", category);
    tags: [..] string;
    tags.allocator = temp;
    for i: 0..t.tag_count - 1 array_add(*tags, store.tags[t.tags[i]].label);
    print_field(doc, "Tags", join(..tags, separator = ", ",, temp));

    print_section(doc, "Payment");
    if t.status == .HELD print_field(doc, "Status", "Held, waiting to settle", color = PRINT_HELD);
    else                 print_field(doc, "Status", "Settled");
    print_field(doc, "Type", t.transaction_type);
    if t.card_method != .NONE print_field(doc, "Method", CARD_METHOD_NAMES[t.card_method]);
    if t.card_suffix.count print_field(doc, "Card", tprint("•••• %", t.card_suffix));
    print_field(doc, "Paid by", t.performer);
    if t.has_foreign print_field(doc, "Foreign amount", format_foreign(t.foreign_currency, t.foreign_value));
    if t.has_hold && t.hold_amount != t.amount print_field(doc, "Held at", format_money(t.hold_amount, .POSITIVE), color = PRINT_HELD);
    if t.has_round_up {
        text := format_money(t.round_up, .POSITIVE);
        if t.round_up_boost text = tprint("% (incl. % boost)", text, format_money(-t.round_up_boost));
        print_field(doc, "Round Up", text);
    }
    if t.has_cashback print_field(doc, "Cashback", tprint("% · %", format_money(t.cashback, .ALWAYS), t.cashback_description), color = PRINT_POSITIVE);

    print_section(doc, "Message and note");
    print_field(doc, "Message", t.message);
    print_field(doc, "Note", t.note);

    print_section(doc, "Record");
    print_field(doc, "Raw text", t.raw_text, mono = true);
    print_field(doc, "Created", format_timestamp_full(t.created), mono = true);
    if t.has_settled print_field(doc, "Settled", format_timestamp_full(t.settled), mono = true);
    else             print_field(doc, "Settled", "Not yet", color = PRINT_HELD);
    if t.attachment_id.count print_field(doc, "Receipt", "Attached in Up");
    print_field(doc, "Transaction ID", t.id, mono = true);
}

// The transactions by when they happened, oldest first. The store keeps
// them newest first.
oldest_first :: (indices: [] s32) -> [] s32 {
    sorted := array_copy(indices,, temp);
    quick_sort(sorted, (a: s32, b: s32) -> int { return b - a; });
    return sorted;
}

// "2026-07-01 to 2026-10-07", or the one day they're all from.
date_range_name :: (indices: [] s32) -> string {
    first, last := store.transactions[indices[0]].day, store.transactions[indices[0]].day;
    for indices {
        first = min(first, store.transactions[it].day);
        last  = max(last, store.transactions[it].day);
    }
    iso :: (day: s64) -> string {
        d := civil_from_days(day);
        return tprint("%-%-%", d.year, pad2(d.month), pad2(d.day));
    }
    return ifx first == last then iso(first) else tprint("% to %", iso(first), iso(last));
}
