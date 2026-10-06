// Small shared pieces: account ordering, period presets, category lists for
// pickers and filters, and search matching.

// Spending accounts first (yours, then joint), then savers by balance, then
// home loans: the order Up's own app uses.
account_order :: () -> [] s32 {
    order := NewArray(store.accounts.count, s32,, temp);
    for 0..order.count - 1 order[it] = cast(s32) it;
    rank :: (a: *Account) -> int {
        if a.type == .TRANSACTIONAL return ifx a.ownership == .JOINT then 1 else 0;
        if a.type == .SAVER return 2;
        if a.type == .HOME_LOAN return 3;
        return 4;
    }
    // Insertion sort: there are only a handful.
    for i: 1..order.count - 1 {
        j := i;
        while j > 0 {
            a := *store.accounts[order[j - 1]];
            b := *store.accounts[order[j]];
            ra, rb := rank(a), rank(b);
            swap_needed := ra > rb || (ra == rb && a.type == .SAVER && a.balance < b.balance);
            if !swap_needed break;
            order[j - 1], order[j] = order[j], order[j - 1];
            j -= 1;
        }
    }
    return order;
}

account_type_label :: (a: *Account) -> string {
    if a.type == {
        case .TRANSACTIONAL; return ifx a.ownership == .JOINT then "2Up spending" else "Spending";
        case .SAVER;         return ifx a.ownership == .JOINT then "2Up saver" else "Saver";
        case .HOME_LOAN;     return "Home loan";
    }
    return "Account";
}

// Account filter: "All accounts", then each account in display order.
account_filter_items :: () -> [] Dropdown_Item, [] s32 {
    order := account_order();
    items := NewArray(order.count + 1, Dropdown_Item,, temp);
    map := NewArray(order.count + 1, s32,, temp);
    items[0].label = "All accounts";
    map[0] = -1;
    for order {
        items[it_index + 1].label = store.accounts[it].name;
        items[it_index + 1].detail = format_money_whole(store.accounts[it].balance);
        map[it_index + 1] = it;
    }
    return items, map;
}

PERIOD_LABELS :: string.["All time", "This month", "Last month", "Last 30 days", "Last 90 days", "This year", "Last 12 months"];

// The period for a PERIOD_LABELS index; ok = false for "All time".
period_from_index :: (index: int, today: s64) -> Period, bool {
    this_month := month_key_from_day(today);
    if index == {
        case 1; return .{first_day_of_month(this_month), today}, true;
        case 2; return month_period(this_month - 1), true;
        case 3; return .{today - 29, today}, true;
        case 4; return .{today - 89, today}, true;
        case 5; return .{days_from_civil(civil_from_days(today).year, 1, 1), today}, true;
        case 6; return .{today - 364, today}, true;
    }
    return .{}, false;
}

// Category filter: everything selectable, parents included (a parent
// matches all its children). Item -> category index; -1 all, -2 uncategorised.
category_filter_items :: () -> [] Dropdown_Item, [] s32 {
    items: [..] Dropdown_Item;
    map:   [..] s32;
    items.allocator = temp;
    map.allocator = temp;
    array_add(*items, .{label = "All categories"});   array_add(*map, -1);
    array_add(*items, .{label = "Uncategorised"});    array_add(*map, -2);
    for pid: PARENT_CATEGORY_IDS {
        parent := store_find_category(*store, pid);
        if parent < 0 continue;
        array_add(*items, .{label = store.categories[parent].name, dot = parent_color(parent)});
        array_add(*map, parent);
        for c, ci: store.categories {
            if c.parent != parent continue;
            array_add(*items, .{label = c.name, indent = true});
            array_add(*map, cast(s32) ci);
        }
    }
    return items, map;
}

// Category picker for a transaction: parents are headings (the API only
// assigns child categories). Item -> category index; -1 = none.
category_picker_items :: () -> [] Dropdown_Item, [] s32 {
    items: [..] Dropdown_Item;
    map:   [..] s32;
    items.allocator = temp;
    map.allocator = temp;
    array_add(*items, .{label = "Uncategorised"}); array_add(*map, -1);
    for pid: PARENT_CATEGORY_IDS {
        parent := store_find_category(*store, pid);
        if parent < 0 continue;
        array_add(*items, .{label = store.categories[parent].name, header = true, dot = parent_color(parent)});
        array_add(*map, -3);
        for c, ci: store.categories {
            if c.parent != parent continue;
            array_add(*items, .{label = c.name});
            array_add(*map, cast(s32) ci);
        }
    }
    return items, map;
}

// Tag filter: "All tags", "Untagged", then each tag by name with how many
// transactions carry it. Item -> tag index; -1 all, -2 untagged.
tag_filter_items :: () -> [] Dropdown_Item, [] s32 {
    order := NewArray(store.tags.count, s32,, temp);
    for 0..order.count - 1 order[it] = cast(s32) it;
    quick_sort(order, (a: s32, b: s32) -> int {
        c := compare_nocase(store.tags[a].label, store.tags[b].label);
        return ifx c then c else a - b;
    });
    items := NewArray(order.count + 2, Dropdown_Item,, temp);
    map := NewArray(order.count + 2, s32,, temp);
    items[0].label = "All tags"; map[0] = -1;
    items[1].label = "Untagged"; map[1] = -2;
    for order {
        items[it_index + 2].label = store.tags[it].label;
        if it < analytics.tags.count items[it_index + 2].detail = format_grouped(analytics.tags[it].count);
        map[it_index + 2] = it;
    }
    return items, map;
}

tag_matches :: (t: *Transaction, filter: s32) -> bool {
    if filter == -1 return true;
    if filter == -2 return t.tag_count == 0;
    return txn_has_tag(t, filter);
}

index_of_value :: (map: [] s32, value: s32) -> int {
    for map if it == value return it_index;
    return 0;
}

category_matches :: (t: *Transaction, filter: s32) -> bool {
    if filter == -1 return true;
    if filter == -2 return t.category < 0 && t.categorizable;
    return t.category == filter || t.parent_category == filter;
}

// Case-insensitive substring; `needle` must already be lower case.
text_contains :: (hay: string, needle: string) -> bool {
    if needle.count == 0 return true;
    if hay.count < needle.count return false;
    first := needle[0];
    for i: 0..hay.count - needle.count {
        c := hay[i];
        if c >= #char "A" && c <= #char "Z" c += 32;
        if c != first continue;
        match := true;
        for j: 1..needle.count - 1 {
            h := hay[i + j];
            if h >= #char "A" && h <= #char "Z" h += 32;
            if h != needle[j] { match = false; break; }
        }
        if match return true;
    }
    return false;
}

to_lower_temp :: (s: string) -> string {
    result := copy_string(s,, temp);
    for 0..result.count - 1 {
        c := result[it];
        if c >= #char "A" && c <= #char "Z" result[it] = c + 32;
    }
    return result;
}

// Matches description, raw text, message, note, category, account, tags,
// and amounts ("12.50" finds $12.50 either way).
txn_matches :: (t: *Transaction, needle: string) -> bool {
    if !needle.count return true;
    if text_contains(t.description, needle) return true;
    if text_contains(t.raw_text, needle) return true;
    if text_contains(t.message, needle) return true;
    if text_contains(t.note, needle) return true;
    if t.category >= 0 && text_contains(store.categories[t.category].name, needle) return true;
    if t.account >= 0 && text_contains(store.accounts[t.account].name, needle) return true;
    for 0..t.tag_count - 1 if text_contains(store.tags[t.tags[it]].label, needle) return true;
    if needle[0] >= #char "0" && needle[0] <= #char "9" || needle[0] == #char "$" {
        v := abs(t.amount);
        plain := tprint("%.%", v / 100, pad2(v % 100));
        n := needle;
        if n[0] == #char "$" advance(*n, 1);
        if begins_with(plain, n) return true;
    }
    return false;
}

// The day header text: "Today", "Yesterday", or "Tue 6 Oct".
day_label :: (day: s64, today: s64) -> string {
    if day == today return tprint("Today · %", format_weekday_date(day, today));
    if day == today - 1 return tprint("Yesterday · %", format_weekday_date(day, today));
    return format_weekday_date(day, today);
}
