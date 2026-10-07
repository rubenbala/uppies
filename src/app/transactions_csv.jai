// Several transactions as a CSV file, for a spreadsheet or accounting
// software: a header row, then a row for each transaction, oldest first.
//
// Amounts are plain signed numbers in dollars ("-29.13", "1500.00") so a
// spreadsheet reads them as numbers; money out is negative. Dates are ISO
// ("2026-10-06"). The file is UTF-8 with a byte order mark, which Excel
// needs to read anything beyond ASCII, and CRLF line endings (RFC 4180).
//
// Text that starts like a formula (=, +, -, @) gets a leading apostrophe:
// messages and notes can come from other people, and a spreadsheet would
// otherwise run them.

// Asks where to save it and saves it.
save_transactions_csv :: (indices: [] s32) {
    if !indices.count return;
    save_with_dialog(transactions_csv(indices), file_name_from_parts("csv", "Transactions", date_range_name(indices)), "Save as CSV", "CSV document", "csv");
}

// The file's bytes (temporary storage).
transactions_csv :: (indices: [] s32) -> string {
    b: String_Builder;
    b.allocator = temp;
    append(*b, "\xEF\xBB\xBF");
    csv_row(*b, .["Date", "Time", "Description", "Amount (AUD)", "Status", "Account", "Transfer account",
                  "Category", "Parent category", "Tags", "Type", "Method", "Card", "Paid by", "Message", "Note",
                  "Foreign amount", "Foreign currency", "Round Up (AUD)", "Cashback (AUD)", "Raw text",
                  "Created", "Settled", "Transaction ID"]);
    for oldest_first(indices) {
        t := *store.transactions[it];
        category, parent := "", "";
        if t.category >= 0 {
            category = category_name(*store, t.category);
            root := category_root(*store, t.category);
            if root != t.category parent = category_name(*store, root);
        }
        tags: [..] string;
        tags.allocator = temp;
        for i: 0..t.tag_count - 1 array_add(*tags, store.tags[t.tags[i]].label);

        csv_row(*b, .[
            format_date_iso(t.day),
            format_time(t.created),
            csv_text(t.description),
            csv_money(t.amount),
            ifx t.status == .HELD then "Held" else "Settled",
            csv_text(account_name(*store, t.account)),
            csv_text(account_name(*store, t.transfer_account)),
            csv_text(category),
            csv_text(parent),
            csv_text(join(..tags, separator = "; ",, temp)),
            csv_text(t.transaction_type),
            ifx t.card_method != .NONE then CARD_METHOD_NAMES[t.card_method] else "",
            csv_text(t.card_suffix),
            csv_text(t.performer),
            csv_text(t.message),
            csv_text(t.note),
            ifx t.has_foreign then t.foreign_value else "",
            ifx t.has_foreign then csv_text(t.foreign_currency) else "",
            ifx t.has_round_up then csv_money(t.round_up) else "",
            ifx t.has_cashback then csv_money(t.cashback) else "",
            csv_text(t.raw_text),
            format_timestamp_full(t.created),
            ifx t.has_settled then format_timestamp_full(t.settled) else "",
            csv_text(t.id),
        ]);
    }
    return builder_to_string(*b,, temp);
}

#scope_file

// One line: the fields separated by commas, each quoted if it has to be.
csv_row :: (b: *String_Builder, fields: [] string) {
    for fields {
        if it_index append(b, ",");
        needs_quotes := false;
        for c: cast([] u8) it if c == #char "," || c == #char "\"" || c == #char "\n" || c == #char "\r" { needs_quotes = true; break; }
        if it.count && (it[0] == #char " " || it[it.count - 1] == #char " ") needs_quotes = true;
        if !needs_quotes { append(b, it); continue; }
        append(b, "\"");
        for c: cast([] u8) it {
            if c == #char "\"" append(b, "\"\"");
            else append(b, c);
        }
        append(b, "\"");
    }
    append(b, "\r\n");
}

// Text a spreadsheet won't take for a formula.
csv_text :: (text: string) -> string {
    if !text.count return text;
    c := text[0];
    if c == #char "=" || c == #char "+" || c == #char "-" || c == #char "@" || c == #char "\t" || c == #char "\r" return tprint("'%", text);
    return text;
}

// "-29.13", "1500.00": no dollar sign or grouping, so it reads as a number.
csv_money :: (cents: s64) -> string {
    v := abs(cents);
    return tprint("%1%2.%3", ifx cents < 0 then "-" else "", v / 100, pad2(v % 100));
}
