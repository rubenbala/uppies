// `uppies.exe -selftest`: runs the sample API through the real parser and
// store, and checks the formatting and parsing helpers. Exit code 0 = pass.

selftest :: () -> int {
    demo_init();
    failures := 0;
    check :: (ok: bool, what: string) #expand {
        if !ok { print("FAIL: %\n", what); `failures += 1; }
        else print("ok:   %\n", what);
    }
    ORIGIN :: "https://api.up.com.au";

    r := demo_execute("GET", "/api/v1/accounts?page%5Bsize%5D=100", "");
    doc, ok := json_parse(r.body);
    check(ok && r.status == 200, "accounts parse");
    accounts: [..] Account;
    for * json_array(json_get(*doc, "data")) array_add(*accounts, parse_account(it));
    store_merge_accounts(*store, accounts);
    check(store.accounts.count == 6, tprint("6 accounts (got %)", store.accounts.count));
    for store.accounts print("      % % % %\n", it.name, it.type, it.ownership, format_money(it.balance));

    r = demo_execute("GET", "/api/v1/categories", "");
    doc, ok = json_parse(r.body);
    categories: [..] Category;
    for * json_array(json_get(*doc, "data")) array_add(*categories, parse_category(it));
    store_merge_categories(*store, categories);
    check(store.categories.count > 40, tprint("categories (got %)", store.categories.count));

    path := "/api/v1/transactions?page%5Bsize%5D=100";
    pages := 0;
    start := seconds_since_init();
    while path.count {
        r = demo_execute("GET", path, "");
        doc, ok = json_parse(r.body);
        if !ok { print("parse error: %\n", slice(r.body, 0, min(r.body.count, 400))); break; }
        batch: [..] Transaction;
        for * json_array(json_get(*doc, "data")) array_add(*batch, parse_transaction(it, *store));
        store_merge_transactions(*store, batch, 0);
        next := json_string(json_at(*doc, "links", "next"));
        path = ifx next.count then copy_string(slice(next, ORIGIN.count, next.count - ORIGIN.count)) else "";
        pages += 1;
    }
    print("      % pages, % transactions in % s (incl. simulated latency)\n", pages, store.transactions.count, formatFloat(seconds_since_init() - start, trailing_width = 2));
    check(store.transactions.count > 2000, "transactions loaded");

    sorted := true;
    for 1..store.transactions.count - 1 if store.transactions[it].created.utc > store.transactions[it - 1].created.utc sorted = false;
    check(sorted, "newest first");
    held := 0;
    for store.transactions if it.status == .HELD held += 1;
    check(held > 0, tprint("held transactions present (%)", held));

    // Each account's balance minus everything in its history is the balance
    // it had before the history starts; it must not be negative.
    for a, ai: store.accounts {
        sum: s64;
        for store.transactions if it.account == ai sum += balance_effect(*it);
        print("      % balance % = opening % + history %\n", a.name, format_money(a.balance), format_money(a.balance - sum), format_money(sum));
        check(a.balance - sum >= 0, tprint("% opening balance not negative", a.name));
    }

    t := *store.transactions[0];
    print("      newest: % | % | % | % | %\n", format_timestamp_full(t.created), t.description, format_money(t.amount), category_name(*store, t.category), t.status);
    check(store_find_transaction(*store, t.id) == 0, "lookup by id");

    takeaway := store_find_category(*store, "takeaway");
    check(takeaway >= 0, "category lookup");
    r = demo_execute("PATCH", tprint("/api/v1/transactions/%/relationships/category", t.id), "{\"data\":{\"type\":\"categories\",\"id\":\"takeaway\"}}");
    check(r.status == 204 || r.status == 403, tprint("categorise (status %)", r.status));
    r = demo_execute("PATCH", tprint("/api/v1/transactions/%/relationships/category", t.id), "{\"data\":{\"type\":\"categories\",\"id\":\"good-life\"}}");
    check(r.status == 422 || r.status == 403, tprint("parent category rejected (status %)", r.status));
    print("      error document: %\n", parse_api_error(r.body));

    r = demo_execute("GET", "/api/v1/webhooks", "");
    doc, ok = json_parse(r.body);
    hooks := json_array(json_get(*doc, "data"));
    check(hooks.count == 2, "webhooks listed");
    if hooks.count == 2 {
        w := parse_webhook(*hooks[1]);
        r = demo_execute("GET", tprint("/api/v1/webhooks/%/logs?%", w.id, query_param("page[size]", "30")), "");
        doc, ok = json_parse(r.body);
        logs := json_array(json_get(*doc, "data"));
        check(logs.count == 30, tprint("webhook logs page (got %)", logs.count));
        if logs.count {
            l := parse_webhook_log(*logs[0]);
            print("      log: % % % %\n", l.event_type, l.delivery, l.status_code, format_timestamp_full(l.created));
        }
    }

    // JSON edge cases. BS is a backslash, so the escapes reach the parser.
    BS :: "\\";
    text := tprint("{\"a\":\"%1u00e9%1ud83d%1ude00 %1\" %1n\",\"b\":[1,-2.5e2,true,null],\"c\":9007199254740993}", BS);
    j, jok := json_parse(text);
    check(jok, "parses escapes");
    a := json_string(json_get(*j, "a"));
    check(a.count == 2 + 4 + 1 + 1 + 1 + 1 && a[0] == 0xC3 && a[1] == 0xA9 && a[2] == 0xF0, tprint("unicode escapes (% bytes)", a.count));
    check(json_int(json_get(*j, "c")) == 9007199254740993, "64-bit integers exact");
    check(json_array(json_get(*j, "b")).count == 4, "array items");
    _, bad := json_parse("{\"a\":}");
    check(!bad, "rejects malformed JSON");
    _, bad2 := json_parse("[1,2");
    check(!bad2, "rejects truncated JSON");

    ts, tok := parse_rfc3339("2024-08-05T05:16:50+10:00");
    check(tok && ts.utc == 1722799010 && ts.offset == 600, "rfc3339 parse");
    check(format_timestamp_full(ts) == "2024-08-05 05:16:50 +10:00", tprint("format full: %", format_timestamp_full(ts)));
    check(format_rfc3339_utc(ts.utc) == "2024-08-04T19:16:50Z", tprint("format utc: %", format_rfc3339_utc(ts.utc)));
    check(format_money(-123456) == tprint("%$1,234.56", MINUS_SIGN), tprint("money: %", format_money(-123456)));
    check(format_money(5, .ALWAYS) == "+$0.05", "money sign");
    check(format_money(-123456, .POSITIVE) == "$1,234.56" && format_money(5, .POSITIVE) == "+$0.05" && format_money(0, .POSITIVE) == "$0.00", "money with only money in signed");
    check(format_money_compact(1234500) == "$12k", tprint("compact: %", format_money_compact(1234500)));
    check(format_money_compact(123450) == "$1.2k", tprint("compact: %", format_money_compact(123450)));
    check(format_grouped(1234567) == "1,234,567", "grouping");
    encoded := url_encode("filter[since]");
    check(encoded == "filter%5Bsince%5D" || encoded == "filter%5bsince%5d", tprint("url encode: %", encoded));
    check(weekday_from_days(days_from_civil(2026, 10, 6)) == 1, "weekday (2026-10-06 is a Tuesday)");
    d := civil_from_days(days_from_civil(2024, 2, 29));
    check(d.year == 2024 && d.month == 2 && d.day == 29, "civil round trip");

    // Secrets at rest: DPAPI (Windows) or the Keychain key (macOS) round trip.
    secret := "up:yeah:not-a-real-token-0123456789";
    cipher, protected := platform_protect(secret);
    check(protected && cipher != secret, "token encrypts");
    plain, unprotected := platform_unprotect(cipher);
    check(unprotected && plain == secret, "token decrypts");
    if protected {
        _, tampered := platform_unprotect(slice(cipher, 0, cipher.count - 1));
        check(!tampered, "tampered ciphertext is rejected");
        bound, bound_ok := platform_protect(secret, "entropy a");
        _, other_entropy := platform_unprotect(bound, "entropy b");
        same, same_ok := platform_unprotect(bound, "entropy a");
        check(bound_ok && !other_entropy && same_ok && same == secret, "a secret bound to entropy opens only with it");
    }
    check(mask_token(secret) == tprint("up:yeah:%2%1", "6789", "••••••••"), tprint("token masking: %", mask_token(secret)));

    // The local store file. First AES-256-GCM itself, against NIST's test
    // case 14 (zero key, zero nonce, one zero block).
    {
        zeros: [32] u8;
        nonce: [AES_NONCE_SIZE] u8;
        block: [16] u8;
        c, tag, gcm_ok := platform_aes_gcm_encrypt(zeros, nonce, .[], block);
        hex :: (b: [] u8) -> string {
            builder: String_Builder;
            builder.allocator = temp;
            for b print_to_builder(*builder, "%", formatInt(it, base = 16, minimum_digits = 2));
            return to_lower_temp(builder_to_string(*builder,, temp));
        }
        check(gcm_ok && hex(c) == "cea7403d4d606b6e074ec5d3baf39d18", tprint("AES-256-GCM ciphertext (NIST): %", hex(c)));
        check(hex(tag) == "d0d1c8a799996bf0265b98b5d48ab919", tprint("AES-256-GCM tag (NIST): %", hex(tag)));
        p, dec_ok := platform_aes_gcm_decrypt(zeros, nonce, .[], c, tag);
        check(dec_ok && p.count == 16 && p[0] == 0 && p[15] == 0, "AES-256-GCM decrypts");
        tag[0] ^= 1;
        _, forged := platform_aes_gcm_decrypt(zeros, nonce, .[], c, tag);
        check(!forged, "AES-256-GCM rejects a forged tag");
    }
    {
        meta := Store_File_Meta.{saved_utc = 1, last_sync_utc = 1759700000, last_full_check_utc = 1759600000, history = 2, history_complete = true, oldest_loaded_utc = 1690000000};
        copy: Store;
        start = seconds_since_init();
        status := store_file_roundtrip_test(*store, *copy, meta, secret);
        print("      % transactions: saved and reopened in % ms\n", store.transactions.count, formatFloat((seconds_since_init() - start) * 1000, trailing_width = 1));
        check(status == .OK, tprint("store file round trip (%)", status));
        same := copy.transactions.count == store.transactions.count && copy.accounts.count == store.accounts.count
             && copy.categories.count == store.categories.count && copy.tags.count == store.tags.count;
        for a, i: store.accounts {
            if !same break;
            b := copy.accounts[i];
            same = a.id == b.id && a.name == b.name && a.balance == b.balance && a.type == b.type && a.ownership == b.ownership && a.created.utc == b.created.utc;
        }
        for a, i: store.transactions {
            if !same break;
            b := *copy.transactions[i];
            same = a.id == b.id && a.description == b.description && a.raw_text == b.raw_text && a.message == b.message && a.note == b.note
                && a.amount == b.amount && a.hold_amount == b.hold_amount && a.round_up == b.round_up && a.cashback == b.cashback
                && a.created.utc == b.created.utc && a.created.offset == b.created.offset && a.settled.utc == b.settled.utc
                && a.account == b.account && a.transfer_account == b.transfer_account && a.category == b.category && a.parent_category == b.parent_category
                && a.tag_count == b.tag_count && a.status == b.status && a.card_method == b.card_method && a.day == b.day
                && a.has_hold == b.has_hold && a.has_foreign == b.has_foreign && a.foreign_value == b.foreign_value && a.attachment_id == b.attachment_id;
            for t: 0..a.tag_count - 1 if same same = copy.tags[b.tags[t]].label == store.tags[a.tags[t]].label;
            if same same = store_find_transaction(*copy, a.id) == i;
            if !same print("      first difference at transaction % (%)\n", i, a.id);
        }
        check(same, "every account, category, tag and transaction survives the round trip");
        store_reset(*copy);

        check(store_file_roundtrip_test(*store, *copy, meta, secret, tamper = true) == .CORRUPT, "an altered store file is rejected");
        check(copy.transactions.count == 0, "nothing from a rejected file is loaded");
        check(store_file_roundtrip_test(*store, *copy, meta, secret, wrong_secret = "up:yeah:another-token") == .LOCKED, "another token can't open the store file");
    }

    // Comparison periods.
    oct := month_key(2026, 10);
    so_far := Period.{first_day_of_month(oct), days_from_civil(2026, 10, 6)};
    before := comparison_period(so_far);
    check(before.first == days_from_civil(2026, 9, 1) && before.last == days_from_civil(2026, 9, 6), tprint("month so far compares with the same days: %", period_label(before)));
    whole := month_period(oct - 1);
    before = comparison_period(whole);
    check(before.first == days_from_civil(2026, 8, 1) && before.last == days_from_civil(2026, 8, 31), tprint("whole month compares with the month before: %", period_label(before)));

    // Financial-year periods (1 July – 30 June).
    fy_check :: (today: s64, index: int, first: s64, last: s64, what: string) #expand {
        p, has := period_from_index(index, today);
        check(has && p.first == first && p.last == last, tprint("%: % – %", what, format_date(p.first), format_date(p.last)));
    }
    oct7 := days_from_civil(2026, 10, 7);
    fy_check(oct7, 7, days_from_civil(2026, 7, 1), oct7, "current financial year after July");
    fy_check(oct7, 8, days_from_civil(2025, 7, 1), days_from_civil(2026, 6, 30), "last financial year after July");
    mar15 := days_from_civil(2026, 3, 15);
    fy_check(mar15, 7, days_from_civil(2025, 7, 1), mar15, "current financial year before July");
    fy_check(mar15, 8, days_from_civil(2024, 7, 1), days_from_civil(2025, 6, 30), "last financial year before July");
    jul1 := days_from_civil(2026, 7, 1);
    fy_check(jul1, 7, jul1, jul1, "financial year starts on 1 July");
    jun30 := days_from_civil(2026, 6, 30);
    fy_check(jun30, 7, days_from_civil(2025, 7, 1), jun30, "financial year ends on 30 June");
    check(format_change_percent(2000, 100) == "×20", tprint("big increases read as multiples: %", format_change_percent(2000, 100)));

    // Printing: a transaction makes a well-formed PDF, and so does a
    // document long enough to need several pages.
    pdf := print_transaction_pdf(0);
    check(begins_with(pdf, "%PDF-1.4\n") && ends_with(pdf, "%%EOF\n"), tprint("transaction PDF (% bytes)", pdf.count));
    check(pdf_cross_references_ok(pdf), "every cross-reference in the transaction PDF points at its object");
    several: [..] s32;
    several.allocator = temp;
    for 0..min(store.transactions.count, 120) - 1 array_add(*several, cast(s32) it);
    pdf = print_statement_pdf(several);
    check(begins_with(pdf, "%PDF-1.4\n") && pdf_cross_references_ok(pdf), tprint("statement of % transactions (% bytes)", several.count, pdf.count));
    pdf = print_transactions_pdf(.[several[0], several[1], several[2]]);
    check(begins_with(pdf, "%PDF-1.4\n") && pdf_cross_references_ok(pdf) && contains(pdf, "Page 3 of"), tprint("three transactions, a page or more each (% bytes)", pdf.count));
    long: Print_Doc;
    print_begin(*long, "Test", "Long document");
    for 1..90 print_field(*long, tprint("Field %", it), "A value long enough that it has to wrap onto a second line in the value column of the page.");
    long_pages := long.pdf.pages.count;
    pdf = print_finish(*long);
    check(long_pages > 1 && pdf_cross_references_ok(pdf), tprint("a long PDF flows onto % pages", long_pages));
    e := pdf_encode("é–“”−•€");
    check(e.count == 7 && e[0] == 0xE9 && e[1] == 0x96 && e[2] == 0x93 && e[3] == 0x94 && e[4] == 0x96 && e[5] == 0x95 && e[6] == 0x80, "PDF text in WinAnsi");
    check(pdf_encode("Pizza 🍕 日本") == "Pizza  ??", tprint("emoji left out, the rest '?': \"%\"", pdf_encode("Pizza 🍕 日本")));
    lines := pdf_wrap(.REGULAR, 10, "Wraps at spaces, and breaks a3f9c1e2-7b4d-4e8a-9c6f-0d2b5e8a1f47 between characters.\nKeeps line breaks.", 60);
    fits := lines.count > 3;
    for lines if pdf_measure(.REGULAR, 10, it) > 60 fits = false;
    check(fits && lines[lines.count - 1] == "breaks.", tprint("PDF text wraps to its width (% lines)", lines.count));
    name := print_file_name("Transaction", " A/B: \"C\"? ", "2026-10-06");
    check(name == "Transaction - A B C - 2026-10-06.pdf", tprint("file names drop what Windows doesn't allow: %", name));

    // Every icon has a glyph in the icon font or a fallback.
    if fonts_init() && theme_load_fonts() && fonts.icons {
        missing: [..] string;
        missing.allocator = temp;
        for type_info(Icon).values {
            icon := cast(Icon) it;
            if icon == .NONE continue;
            if !font_has_glyph(fonts.icons, icon_code_point(icon)) array_add(*missing, type_info(Icon).names[it_index]);
        }
        check(!missing.count, tprint("every icon has a glyph (missing: %)", missing));
    } else {
        check(false, "the icon font loads");
    }

    print("\n% failure(s)\n", failures);
    return ifx failures then 1 else 0;
}

#scope_file

// Follows startxref to the cross-reference table and checks that each entry
// lands on "N 0 obj": what a PDF reader needs to find anything.
pdf_cross_references_ok :: (pdf: string) -> bool {
    at := find_index_from_right(pdf, "startxref\n");
    if at < 0 return false;
    xref, xref_ok := string_to_int(slice(pdf, at + 10, pdf.count - at - 10));
    if !xref_ok || xref <= 0 || xref >= pdf.count return false;
    table := slice(pdf, xref, pdf.count - xref);
    if !begins_with(table, "xref\n0 ") return false;
    count, count_ok := string_to_int(slice(table, 7, table.count - 7));
    if !count_ok || count < 2 return false;
    first := find_index_from_left(table, "0000000000 65535 f \n");
    if first < 0 return false;
    for 1..count - 1 {
        entry := xref + first + it * 20;
        if entry + 20 > pdf.count return false;
        offset, offset_ok := string_to_int(slice(pdf, entry, 10));
        if !offset_ok || offset <= 0 || offset >= pdf.count return false;
        if !begins_with(slice(pdf, offset, pdf.count - offset), tprint("% 0 obj\n", it)) return false;
    }
    return true;
}
