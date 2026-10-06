// A transaction as a PDF: everything Up says about it, laid out like the
// inspector (amount and when, then category and tags, how it was paid, any
// message or note, and the record: raw text, timestamps, the id).

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
    t := *store.transactions[index];
    doc: Print_Doc;
    print_begin(*doc, "Transaction", t.description);

    print_title(*doc, t.description);
    held := t.status == .HELD;
    print_amount(*doc, format_money(t.amount, .ALWAYS), ifx t.amount > 0 then PRINT_POSITIVE else PRINT_TEXT,
                 ifx held then "Held" else "Settled", ifx held then PRINT_HELD else PRINT_SECONDARY, ifx held then PRINT_HELD_WASH else PRINT_WASH);
    when := tprint("% at %", format_date_long(t.day), format_time(t.created));
    if held when = tprint("%, waiting to settle", when);
    print_caption(*doc, when);

    print_section(*doc, "Summary");
    print_field(*doc, "Account", account_name(*store, t.account));
    if is_transfer(t) print_field(*doc, ifx t.amount < 0 then "Transferred to" else "Transferred from", account_name(*store, t.transfer_account));
    category := "";
    if !t.categorizable category = "Not categorisable (transfers, interest and payments to people aren't)";
    else if t.category < 0 category = "Uncategorised";
    else {
        root := category_root(*store, t.category);
        category = store.categories[t.category].name;
        if root != t.category category = tprint("% › %", store.categories[root].name, category);
    }
    print_field(*doc, "Category", category);
    tags: [..] string;
    tags.allocator = temp;
    for i: 0..t.tag_count - 1 array_add(*tags, store.tags[t.tags[i]].label);
    print_field(*doc, "Tags", join(..tags, separator = ", ",, temp));

    print_section(*doc, "Payment");
    print_field(*doc, "Type", t.transaction_type);
    if t.card_method != .NONE print_field(*doc, "Method", CARD_METHOD_NAMES[t.card_method]);
    if t.card_suffix.count print_field(*doc, "Card", tprint("•••• %", t.card_suffix));
    print_field(*doc, "Paid by", t.performer);
    if t.has_foreign print_field(*doc, "Foreign amount", format_foreign(t.foreign_currency, t.foreign_value));
    if t.has_hold && t.hold_amount != t.amount print_field(*doc, "Held at", format_money(t.hold_amount), color = PRINT_HELD);
    if t.has_round_up {
        text := format_money(t.round_up);
        if t.round_up_boost text = tprint("% (incl. % boost)", text, format_money(-t.round_up_boost));
        print_field(*doc, "Round Up", text);
    }
    if t.has_cashback print_field(*doc, "Cashback", tprint("% · %", format_money(t.cashback, .ALWAYS), t.cashback_description), color = PRINT_POSITIVE);

    print_section(*doc, "Message and note");
    print_field(*doc, "Message", t.message);
    print_field(*doc, "Note", t.note);

    print_section(*doc, "Record");
    print_field(*doc, "Raw text", t.raw_text, mono = true);
    print_field(*doc, "Created", format_timestamp_full(t.created), mono = true);
    if t.has_settled print_field(*doc, "Settled", format_timestamp_full(t.settled), mono = true);
    else             print_field(*doc, "Settled", "Not yet", color = PRINT_HELD);
    if t.attachment_id.count print_field(*doc, "Receipt", "Attached in Up");
    print_field(*doc, "Transaction ID", t.id, mono = true);

    return print_finish(*doc);
}
