// Derived views of the store, recomputed only when the store, the day or a
// setting they depend on changes.
//
// Money in and money out leave out transfers between the customer's own
// accounts (a move to a saver is neither income nor spending) unless the
// "exclude transfers" setting is off. Balance history is reconstructed by
// walking back from today's balance through every transaction's effect on
// its account (its amount plus any Round Up swept alongside it).
//
// An account the customer leaves out of totals (Configure on the Accounts
// page) is treated as someone else's: its balance and its own transactions
// count towards no total, and money moved to or from it is income or
// spending, not a transfer between their own accounts. Asked about on its
// own (one account chosen), it is still shown in full.

Tag_Stat :: struct {
    count:     int;
    money_in:  s64;
    money_out: s64;
    first_day: s64;
    last_day:  s64;
}

Analytics :: struct {
    version: u64;
    today:   s64;
    exclude_transfers: bool;
    excluded_version: u64;
    computed: bool;

    first_day: s64;
    day_count: int;
    day_in:   [..] s64;
    day_out:  [..] s64;
    day_txns: [..] s32;

    first_month: s32;
    month_count: int;
    month_in:  [..] s64;
    month_out: [..] s64;
    cat_count: int;
    month_cat:   [..] s64;   // [month * cat_count + category]: net amount (spending is negative).
    month_uncat: [..] s64;   // Categorisable but uncategorised, net.
    month_other: [..] s64;   // Not categorisable (payments to people, fees), net outgoing.

    balance_hist: [..] s64;  // [account * day_count + day]: balance at the end of the day.
    acct_in_30:   [..] s64;
    acct_out_30:  [..] s64;
    acct_n_30:    [..] s32;

    held_count: int;
    held_total: s64;
    uncategorised_count: int;
    uncategorised_total: s64;

    tags: [..] Tag_Stat;
}

analytics: Analytics;

// By account index: left out of totals. Rebuilt when the accounts or the
// customer's choice change.
excluded_accounts: [..] bool;
excluded_count: int;
excluded_key: u64;

excluded_update :: () {
    key := hash_key(store.version, user_data.excluded_version);
    if key == excluded_key return;
    excluded_key = key;
    array_resize(*excluded_accounts, store.accounts.count);
    excluded_count = 0;
    for store.accounts {
        excluded_accounts[it_index] = array_find(user_data.excluded_ids, it.id);
        if excluded_accounts[it_index] excluded_count += 1;
    }
}

account_excluded :: inline (account: int) -> bool {
    return account >= 0 && account < excluded_accounts.count && excluded_accounts[account];
}

// A move between two accounts that both count: neither income nor spending.
is_own_transfer :: inline (t: *Transaction) -> bool {
    return is_transfer(t) && !account_excluded(t.transfer_account);
}

// Money in or out of its own account (for one account's figures).
counts_as_flow :: inline (t: *Transaction) -> bool {
    return !(analytics.exclude_transfers && is_own_transfer(t));
}

// Money in or out of the customer's accounts taken together.
counts_in_totals :: inline (t: *Transaction) -> bool {
    return !account_excluded(t.account) && counts_as_flow(t);
}

analytics_update :: (today: s64) {
    excluded_update();
    a := *analytics;
    if a.computed && a.version == store.version && a.today == today && a.exclude_transfers == settings.exclude_transfers && a.excluded_version == user_data.excluded_version return;
    a.version = store.version;
    a.today = today;
    a.exclude_transfers = settings.exclude_transfers;
    a.excluded_version = user_data.excluded_version;
    a.computed = true;

    txns := store.transactions;
    a.first_day = today;
    for txns a.first_day = min(a.first_day, cast(s64) it.day);
    a.first_day = min(a.first_day, today - 30);
    a.day_count = cast(int) (today - a.first_day + 1);
    reset :: (array: *[..] $T, count: int) {
        array_resize(array, count, initialize = false);
        if count memset(array.data, 0, count * size_of(T));
    }
    reset(*a.day_in, a.day_count);
    reset(*a.day_out, a.day_count);
    reset(*a.day_txns, a.day_count);

    a.first_month = month_key_from_day(a.first_day);
    a.month_count = month_key_from_day(today) - a.first_month + 1;
    a.cat_count = store.categories.count;
    reset(*a.month_in, a.month_count);
    reset(*a.month_out, a.month_count);
    reset(*a.month_cat, a.month_count * a.cat_count);
    reset(*a.month_uncat, a.month_count);
    reset(*a.month_other, a.month_count);

    accounts := store.accounts.count;
    reset(*a.acct_in_30, accounts);
    reset(*a.acct_out_30, accounts);
    reset(*a.acct_n_30, accounts);
    reset(*a.tags, store.tags.count);

    a.held_count = 0;
    a.held_total = 0;
    a.uncategorised_count = 0;
    a.uncategorised_total = 0;

    for * t: txns {
        d := t.day - a.first_day;
        if d < 0 || d >= a.day_count continue;
        m := t.month - a.first_month;
        flow := counts_in_totals(t);
        if t.status == .HELD { a.held_count += 1; a.held_total += t.amount; }
        if flow {
            if t.amount > 0 { a.day_in[d] += t.amount; a.month_in[m] += t.amount; }
            else            { a.day_out[d] -= t.amount; a.month_out[m] -= t.amount; }
            a.day_txns[d] += 1;
            if t.category >= 0 a.month_cat[m * a.cat_count + t.category] += t.amount;
            else if t.categorizable { if t.amount < 0 a.month_uncat[m] += t.amount; }
            else if t.amount < 0 a.month_other[m] += t.amount;
        }
        if t.categorizable && t.category < 0 && t.amount < 0 && !is_transfer(t) {
            a.uncategorised_count += 1;
            a.uncategorised_total += t.amount;
        }
        if t.account >= 0 && today - t.day < 30 && counts_as_flow(t) {
            if t.amount > 0 a.acct_in_30[t.account] += t.amount;
            else a.acct_out_30[t.account] -= t.amount;
            a.acct_n_30[t.account] += 1;
        }
        for 0..t.tag_count - 1 {
            ts := *a.tags[t.tags[it]];
            if ts.count == 0 { ts.first_day = t.day; ts.last_day = t.day; }
            ts.count += 1;
            if t.amount > 0 ts.money_in += t.amount; else ts.money_out -= t.amount;
            ts.first_day = min(ts.first_day, cast(s64) t.day);
            ts.last_day  = max(ts.last_day, cast(s64) t.day);
        }
    }

    // End-of-day balances, walking back from today.
    reset(*a.balance_hist, accounts * a.day_count);
    for acct: 0..accounts - 1 {
        balance := store.accounts[acct].balance;
        hist := a.balance_hist.data + acct * a.day_count;
        i := 0;
        for < d: 0..a.day_count - 1 {
            hist[d] = balance;
            day := a.first_day + d;
            while i < txns.count && txns[i].day >= day {
                if txns[i].account == acct balance -= balance_effect(*txns[i]);
                i += 1;
            }
        }
    }
}

balance_at :: (account: int, day: s64) -> s64 {
    a := *analytics;
    if account < 0 || account >= store.accounts.count || !a.day_count return 0;
    d := clamp(day - a.first_day, 0, a.day_count - 1);
    return a.balance_hist[account * a.day_count + d];
}

total_balance_at :: (day: s64, types: Account_Type = .OTHER) -> s64 {
    total: s64;
    for store.accounts {
        if account_excluded(it_index) || (types != .OTHER && it.type != types) continue;
        total += balance_at(it_index, day);
    }
    return total;
}

// Day range, inclusive.
Period :: struct {
    first: s64;
    last:  s64;
}

period_days :: (p: Period) -> s64 { return p.last - p.first + 1; }

// The same length immediately before.
previous_period :: (p: Period) -> Period {
    n := period_days(p);
    return .{p.first - n, p.first - 1};
}

// What a period is fairly compared with. Whole months compare with the
// same number of months before; a month so far compares with the same days
// of the month before; anything else with the same length just before.
comparison_period :: (p: Period) -> Period {
    first := civil_from_days(p.first);
    if first.day != 1 return previous_period(p);
    first_month := month_key(first.year, first.month);
    last_month := month_key_from_day(p.last);
    months := last_month - first_month + 1;
    month_ends := civil_from_days(p.last + 1).day == 1;
    if month_ends return .{first_day_of_month(first_month - months), first_day_of_month(first_month) - 1};
    if months == 1 {
        start := first_day_of_month(first_month - 1);
        return .{start, min(start + period_days(p) - 1, first_day_of_month(first_month) - 1)};
    }
    // Several months, the last one partial: the same span shifted back.
    start := first_day_of_month(first_month - months);
    return .{start, start + period_days(p) - 1};
}

// "1–6 Sep", "Sep 2026", "Jun – Aug 2026"
period_label :: (p: Period) -> string {
    a := civil_from_days(p.first);
    b := civil_from_days(p.last);
    whole_months := a.day == 1 && civil_from_days(p.last + 1).day == 1;
    if whole_months {
        if a.year == b.year && a.month == b.month return tprint("% %", MONTH_SHORT[a.month - 1], a.year);
        return tprint("% – %", format_month(month_key(a.year, a.month)), format_month(month_key(b.year, b.month)));
    }
    if a.year == b.year && a.month == b.month return tprint("%–% %", a.day, b.day, MONTH_SHORT[a.month - 1]);
    return tprint("% % – % %", a.day, MONTH_SHORT[a.month - 1], b.day, MONTH_SHORT[b.month - 1]);
}

month_period :: (key: int) -> Period {
    first := first_day_of_month(key);
    return .{first, first + days_in_month(key) - 1};
}

// Whether t counts towards one account's figures, or (account -1) towards
// the customer's totals.
counts_for :: inline (t: *Transaction, account: int) -> bool {
    if account >= 0 return t.account == account && counts_as_flow(t);
    return counts_in_totals(t);
}

Flow_Totals :: struct {
    money_in:  s64;
    money_out: s64;
    count:     int;
    largest_out: s64;
    largest_out_index: s32 = -1;
}

// Totals over a period for one account (-1: the ones that count, together).
period_flow :: (p: Period, account := -1) -> Flow_Totals {
    totals: Flow_Totals;
    for * t: store.transactions {
        if t.day > p.last continue;
        if t.day < p.first - 1 break;   // Newest first: nothing older matters (a day of slack for offset changes).
        if t.day < p.first continue;
        if !counts_for(t, account) continue;
        totals.count += 1;
        if t.amount > 0 totals.money_in += t.amount;
        else {
            totals.money_out -= t.amount;
            if -t.amount > totals.largest_out { totals.largest_out = -t.amount; totals.largest_out_index = cast(s32) it_index; }
        }
    }
    return totals;
}

//
// Spending by category over a period, with the previous period beside it.
//

Category_Spend :: struct {
    category: s32;     // -1 uncategorised, -2 other payments.
    parent:   s32;
    spent:    s64;     // Positive: net money out.
    previous: s64;
    count:    int;
}

Spend_Breakdown :: struct {
    key: u64;
    rows: [..] Category_Spend;      // One per category with activity, plus buckets.
    parents: [..] Category_Spend;   // Totals per parent.
    total: s64;
    previous_total: s64;
    previous: Period;   // What it was compared with.
}

// Pages ask for a dozen periods a frame (a chart's months): keep a few, so
// pointers handed out stay valid for the frame and nothing recomputes.
SPEND_CACHE_SIZE :: 32;
spend_cache:      [SPEND_CACHE_SIZE] Spend_Breakdown;
spend_cache_used: [SPEND_CACHE_SIZE] u64;

spend_breakdown :: (p: Period, account := -1) -> *Spend_Breakdown {
    prev := comparison_period(p);
    key := hash_key(store.version, cast(u64) p.first, cast(u64) p.last, cast(u64) (account + 7), cast(u64) settings.exclude_transfers, cast(u64) prev.first, cast(u64) prev.last, user_data.excluded_version);
    slot := 0;
    for spend_cache {
        if it.key == key {
            spend_cache_used[it_index] = ui.frame;
            return *spend_cache[it_index];
        }
        if spend_cache_used[it_index] < spend_cache_used[slot] slot = it_index;
    }
    spend_cache_used[slot] = ui.frame;
    b := *spend_cache[slot];
    b.key = key;
    b.rows.count = 0;
    b.parents.count = 0;
    b.total = 0;
    b.previous_total = 0;

    n := store.categories.count;
    current  := NewArray(n + 2, s64,, temp);
    previous := NewArray(n + 2, s64,, temp);
    counts   := NewArray(n + 2, int,, temp);
    b.previous = prev;
    oldest := min(p.first, prev.first);
    for * t: store.transactions {
        if t.day > p.last continue;
        if t.day < oldest - 1 break;
        in_current := t.day >= p.first;
        in_previous := t.day >= prev.first && t.day <= prev.last;
        if !in_current && !in_previous continue;
        if !counts_for(t, account) || is_own_transfer(t) continue;
        slot := ifx t.category >= 0 then cast(int) t.category else ifx t.categorizable then n else n + 1;
        if slot >= n && t.amount > 0 continue;   // Incoming money isn't spending.
        if in_current { current[slot] -= t.amount; counts[slot] += 1; }
        else previous[slot] -= t.amount;
    }
    for i: 0..n + 1 {
        if current[i] == 0 && previous[i] == 0 && counts[i] == 0 continue;
        row := array_add(*b.rows);
        row.category = cast(s32) (ifx i < n then i else ifx i == n then -1 else -2);
        row.parent = ifx i < n then category_root(*store, cast(s32) i) else -1;
        row.spent = current[i];
        row.previous = previous[i];
        row.count = counts[i];
        b.total += current[i];
        b.previous_total += previous[i];
    }
    // Parent totals, in Up's fixed order.
    for pid: PARENT_CATEGORY_IDS {
        parent := store_find_category(*store, pid);
        if parent < 0 continue;
        total := array_add(*b.parents);
        total.category = parent;
        total.parent = parent;
        for b.rows if it.parent == parent {
            total.spent += it.spent;
            total.previous += it.previous;
            total.count += it.count;
        }
    }
    quick_sort(b.rows, (x: Category_Spend, y: Category_Spend) -> int {
        if x.spent != y.spent return ifx x.spent > y.spent then -1 else 1;
        return x.category - y.category;
    });
    return b;
}

// Index 0..3 for Up's parent categories; -1 otherwise.
parent_slot :: (parent: s32) -> int {
    if parent < 0 || parent >= store.categories.count return -1;
    id := store.categories[parent].id;
    for PARENT_CATEGORY_IDS if it == id return it_index;
    return -1;
}

parent_color :: (parent: s32) -> Color {
    slot := parent_slot(parent);
    return parent_category_color(slot);
}

category_color :: (category: s32) -> Color {
    return parent_color(category_root(*store, category));
}

//
// Merchants: outgoing transactions grouped by description.
//

Merchant_Row :: struct {
    name:     string;   // Points into a transaction's storage.
    count:    int;
    spent:    s64;
    largest:  s64;
    last_day: s64;
    category: s32;      // Of the most recent purchase.
    latest:   s32;      // Transaction index of the most recent purchase.
}

Merchant_List :: struct {
    key: u64;
    rows: [..] Merchant_Row;
    total: s64;
}

merchant_cache: Merchant_List;

merchants :: (p: Period, account := -1) -> *Merchant_List {
    key := hash_key(store.version, cast(u64) p.first, cast(u64) p.last, cast(u64) (account + 7), cast(u64) settings.exclude_transfers, user_data.excluded_version);
    m := *merchant_cache;
    if m.key == key return m;
    m.key = key;
    m.rows.count = 0;
    m.total = 0;
    lookup: Table(string, int);
    lookup.allocator = temp;
    for * t: store.transactions {
        if t.day > p.last continue;
        if t.day < p.first - 1 break;
        if t.day < p.first continue;
        if account >= 0 && t.account != account continue;
        if account < 0 && account_excluded(t.account) continue;
        if is_transfer(t) || t.amount >= 0 || !t.categorizable continue;
        found, index := table_find(*lookup, t.description);
        if !found {
            index = m.rows.count;
            table_set(*lookup, t.description, index);
            row := array_add(*m.rows);
            row.name = t.description;
            row.last_day = t.day;
            row.category = t.category;
            row.latest = cast(s32) it_index;
        }
        row := *m.rows[index];
        row.count += 1;
        row.spent -= t.amount;
        row.largest = max(row.largest, -t.amount);
        m.total -= t.amount;
    }
    quick_sort(m.rows, (x: Merchant_Row, y: Merchant_Row) -> int {
        if x.spent != y.spent return ifx x.spent > y.spent then -1 else 1;
        return compare_strings(x.name, y.name);
    });
    return m;
}

hash_key :: (values: ..u64) -> u64 {
    h: u64 = 0xcbf29ce484222325;
    for values {
        h ^= it;
        h *= 0x100000001b3;
        h ^= h >> 29;
    }
    return h;
}
