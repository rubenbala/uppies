// Recurring payments: subscriptions, bills and income that come round on a
// schedule, found in the transaction history. The Up API says nothing about
// them (scheduled payments are only in its Open Banking API, and card
// subscriptions are charged by the merchant anyway), so they are worked out
// here from the merchant, the dates and the amounts:
//
//   group    transactions by account, merchant (description) and direction,
//            leaving out transfers between the customer's own accounts (a
//            repayment into a loan left out of totals stays), accounts left
//            out of totals, purchases made in person (a tap or a PIN is
//            never a merchant charging a card on file) and money into savers
//            (interest).
//   split    card charges by amount: one merchant can bill for two
//            subscriptions (Apple: iCloud and Apple Music). Direct debits,
//            BPAY and income stay whole: their amounts vary.
//   join     amount groups that follow one another when together they keep
//            the schedule: a price rise continues a subscription.
//   fit      the gaps between charges to a schedule, weekly to yearly. A
//            series is regular when three quarters of its gaps fit; a missed
//            charge now and then (a gap of two periods) is allowed.
//   predict  the next charge: the usual day of the month for monthly and
//            longer schedules, a period after the last one otherwise. The
//            amount is the current price, or the median of the last three
//            when it varies.
//
// Series the customer says aren't recurring (recurring_set_hidden) are still
// found, so they can be shown again, but count towards no totals. They are
// kept in user.bin (see user_data.jai).
//
// Recomputed when the store, the day, the hidden set or the accounts left
// out of totals change.

Recurring_Kind :: enum u8 { SUBSCRIPTION; BILL; INCOME; }
RECURRING_KIND_LABELS :: string.["Subscription", "Bill", "Income"];

Cadence :: enum u8 { WEEKLY; FORTNIGHTLY; FOUR_WEEKLY; MONTHLY; QUARTERLY; YEARLY; }
CADENCE_LABELS :: string.["Weekly", "Fortnightly", "Every 4 weeks", "Monthly", "Quarterly", "Yearly"];

Recurring_Series :: struct {
    id:        u64;      // Stable while the history is: account, merchant, kind, schedule.
    name:      string;   // Points into a transaction's storage.
    kind:      Recurring_Kind;
    cadence:   Cadence;
    account:   s32;
    category:  s32;      // Of the latest charge.
    first:     int;      // Its transactions are recurring.members[first..first + count - 1], oldest first.
    count:     int;
    first_day: s64;
    last_day:  s64;
    next_day:  s64;      // When the next one is expected (may be a day or two past).
    amount:    s64;      // The next one's expected amount, signed like a transaction.
    monthly:   s64;      // What it comes to a month (positive).
    low:       s64;      // Smallest and largest seen (positive).
    high:      s64;
    variable:  bool;     // The amount changes from one to the next (bills, pay).
    previous_amount: s64;   // Before the latest price change (positive); 0 if none.
    changed_day:     s64;   // First charge at the current price.
    missed:    int;      // Charges skipped along the way.
    active:    bool;     // Still going: the next one isn't long overdue.
    hidden:    bool;     // The customer said it isn't recurring.
}

Recurring_State :: struct {
    key: u64;
    series:  [..] Recurring_Series;   // Active first, then the most per month.
    members: [..] s32;                // Transaction indices, series after series.
    of_txn:  [..] s32;                // By transaction index: its series, or -1.

    // Active, shown series only.
    subscriptions_monthly: s64;
    bills_monthly:  s64;
    income_monthly: s64;
    active_count:   int;
    hidden_count:   int;

    hidden: [..] u64;                 // Ids the customer hid (user.bin).
    hidden_version: u64;
}

recurring: Recurring_State;

recurring_update :: (today: s64) {
    key := hash_key(store.version, cast(u64) today, recurring.hidden_version, user_data.excluded_version);
    if recurring.key == key return;
    recurring.key = key;
    recurring_compute(*recurring, *store, today);
}

// The series a transaction belongs to, or null.
recurring_series_of :: (txn_index: s32) -> *Recurring_Series {
    if txn_index < 0 || txn_index >= recurring.of_txn.count return null;
    s := recurring.of_txn[txn_index];
    return ifx s >= 0 then *recurring.series[s] else null;
}

recurring_find :: (id: u64) -> s32 {
    for recurring.series if it.id == id return cast(s32) it_index;
    return -1;
}

// The days between charges: what a schedule is supposed to be, and how far
// a charge may drift from it (weekends, the end of the month).
cadence_days :: (c: Cadence) -> s64 {
    if c == {
        case .WEEKLY;      return 7;
        case .FORTNIGHTLY; return 14;
        case .FOUR_WEEKLY; return 28;
        case .MONTHLY;     return 30;
        case .QUARTERLY;   return 91;
    }
    return 365;
}

// Months per charge for the schedules that keep to a day of the month; 0 for the rest.
cadence_months :: (c: Cadence) -> int {
    if c == {
        case .MONTHLY;   return 1;
        case .QUARTERLY; return 3;
        case .YEARLY;    return 12;
    }
    return 0;
}

// What `amount` (positive) every period comes to a month.
monthly_equivalent :: (amount: s64, c: Cadence) -> s64 {
    if c == {
        case .WEEKLY;      return amount * 52 / 12;
        case .FORTNIGHTLY; return amount * 26 / 12;
        case .FOUR_WEEKLY; return amount * 13 / 12;
        case .MONTHLY;     return amount;
        case .QUARTERLY;   return amount / 3;
    }
    return amount / 12;
}

// "−$18.99 monthly", "$3,412.80 fortnightly", "~$290 quarterly".
recurring_amount_text :: (s: *Recurring_Series) -> string {
    money := ifx s.variable then tprint("~%", format_money_whole(abs(s.amount))) else format_money(abs(s.amount));
    return tprint("% %", money, to_lower_temp(CADENCE_LABELS[s.cadence]));
}

recurring_compute :: (out: *Recurring_State, s: *Store, today: s64) {
    out.series.count = 0;
    out.members.count = 0;
    out.subscriptions_monthly = 0;
    out.bills_monthly = 0;
    out.income_monthly = 0;
    out.active_count = 0;
    out.hidden_count = 0;
    array_resize(*out.of_txn, s.transactions.count, initialize = false);
    for * out.of_txn it.* = -1;

    // Group, oldest first.
    groups: [..] [..] Charge;
    groups.allocator = temp;
    lookup: Table(string, int);
    lookup.allocator = temp;
    for < i: 0..s.transactions.count - 1 {
        t := *s.transactions[i];
        if !could_recur(s, t) continue;
        key := tprint("%\0%\0%", t.account, ifx t.amount > 0 then "in" else "out", t.description);
        found, g := table_find(*lookup, key);
        if !found {
            g = groups.count;
            table_set(*lookup, key, g);
            group := array_add(*groups);
            group.allocator = temp;
        }
        array_add(*groups[g], .{index = cast(s32) i, day = t.day, amount = abs(t.amount)});
    }

    for group: groups {
        if group.count < 2 continue;
        latest := *s.transactions[group[group.count - 1].index];
        if latest.amount > 0 || varies(latest) {
            // Income and bills: the whole group is one series, or none.
            emit(out, s, group, today);
            continue;
        }

        // Card charges: one cluster per price...
        clusters: [..] [..] Charge;
        clusters.allocator = temp;
        reference: [..] s64;
        reference.allocator = temp;
        for c: group {
            best := -1;
            for ref, k: reference {
                if abs(c.amount - ref) > max(100, ref / 10) continue;
                if best < 0 || abs(c.amount - ref) < abs(c.amount - reference[best]) best = k;
            }
            if best < 0 {
                best = clusters.count;
                cluster := array_add(*clusters);
                cluster.allocator = temp;
                array_add(*reference, c.amount);
            }
            array_add(*clusters[best], c);
            reference[best] = c.amount;
        }

        // ...then each joined to the clusters after it that continue its
        // schedule at a new price. Clusters are in order of their first charge.
        used := NewArray(clusters.count, bool,, temp);
        for i: 0..clusters.count - 1 {
            if used[i] continue;
            current := clusters[i];
            for j: i + 1..clusters.count - 1 {
                if used[j] continue;
                next := clusters[j];
                last := current[current.count - 1];
                if next[0].day <= last.day continue;   // Interleaved: another subscription.
                if next[0].amount * 2 > last.amount * 3 || last.amount * 2 > next[0].amount * 3 continue;
                joined: [..] Charge;
                joined.allocator = temp;
                array_add(*joined, ..current);
                array_add(*joined, ..next);
                f := fit(joined, renews(latest));
                if !f.regular || !gap_fits(next[0].day - last.day, f.cadence) continue;
                current = joined;
                used[j] = true;
            }
            emit(out, s, current, today);
        }
    }

    // Series from one account and merchant with the same schedule are told
    // apart by their order: Apple's first monthly subscription, its second.
    for * a: out.series {
        ordinal := 0;
        for * b: out.series {
            if b == a break;
            if b.account == a.account && b.name == a.name && b.kind == a.kind && b.cadence == a.cadence ordinal += 1;
        }
        account_id := ifx a.account >= 0 then s.accounts[a.account].id else "";
        a.id = hash_key(hash_text(account_id), hash_text(a.name), cast(u64) a.kind, cast(u64) a.cadence, cast(u64) ordinal);
        a.hidden = array_find(out.hidden, a.id);
    }

    quick_sort(out.series, (x: Recurring_Series, y: Recurring_Series) -> int {
        if x.active != y.active return ifx x.active then -1 else 1;
        if x.monthly != y.monthly return ifx x.monthly > y.monthly then -1 else 1;
        return compare_strings(x.name, y.name);
    });
    for series, si: out.series {
        for k: 0..series.count - 1 out.of_txn[out.members[series.first + k]] = cast(s32) si;
        if series.hidden { out.hidden_count += 1; continue; }
        if !series.active continue;
        out.active_count += 1;
        if series.kind == {
            case .SUBSCRIPTION; out.subscriptions_monthly += series.monthly;
            case .BILL;         out.bills_monthly += series.monthly;
            case .INCOME;       out.income_monthly += series.monthly;
        }
    }
}

// The active, shown series with a charge expected from `from` to `to`,
// soonest first (temporary storage).
recurring_due :: (from: s64, to: s64) -> [] s32 {
    due: [..] s32;
    due.allocator = temp;
    for recurring.series {
        if !it.active || it.hidden || it.next_day < from || it.next_day > to continue;
        array_add(*due, cast(s32) it_index);
    }
    for i: 1..due.count - 1 {
        j := i;
        while j > 0 && recurring.series[due[j - 1]].next_day > recurring.series[due[j]].next_day {
            due[j - 1], due[j] = due[j], due[j - 1];
            j -= 1;
        }
    }
    return due;
}

// Hides a series (it isn't recurring) or shows it again, and saves that.
recurring_set_hidden :: (id: u64, hidden: bool) {
    found, index := array_find(recurring.hidden, id);
    if hidden == found return;
    if hidden array_add(*recurring.hidden, id);
    else array_unordered_remove_by_index(*recurring.hidden, index);
    recurring.hidden_version += 1;
    user_data_save();
}

#scope_file

Charge :: struct {
    index:  s32;
    day:    s64;
    amount: s64;   // Positive.
}

Fit :: struct {
    regular: bool;
    cadence: Cadence;
    missed:  int;
}

// Could this transaction be one of a series?
could_recur :: (s: *Store, t: *Transaction) -> bool {
    if is_own_transfer(t) || t.amount == 0 || t.account < 0 || t.account >= s.accounts.count || account_excluded(t.account) return false;
    // Money into savers is interest and transfers; pay goes to spending
    // accounts. Money out of a home loan is its interest.
    if t.amount > 0 return s.accounts[t.account].type == .TRANSACTIONAL;
    if s.accounts[t.account].type == .HOME_LOAN return false;
    if t.card_method == {
        case .CONTACTLESS; #through;
        case .CARD_PIN; #through;
        case .MAGNETIC_STRIPE; #through;
        case .BAR_CODE; #through;
        case .OCR;
            return false;   // Bought in person.
    }
    return true;
}

// Direct debits and BPAY: bills whose amount changes from one to the next.
varies :: (t: *Transaction) -> bool {
    return contains(t.transaction_type, "Direct Debit") || contains(t.transaction_type, "BPAY");
}

// Charges two days apart or less are one charge made twice (a retry, a
// correction), as far as the schedule goes.
occurrence_days :: (charges: [] Charge) -> [] s64 {
    days: [..] s64;
    days.allocator = temp;
    for charges if !days.count || it.day - days[days.count - 1] > 2 array_add(*days, it.day);
    return days;
}

// How many periods a gap between charges is (1, or 2 when one was missed),
// or 0 when it doesn't fit the schedule.
gap_periods :: (gap: s64, c: Cadence) -> int {
    tolerance: s64 = ---;
    if c == {
        case .WEEKLY;      tolerance = 1;
        case .FORTNIGHTLY; tolerance = 2;
        case .FOUR_WEEKLY; tolerance = 1;
        case .MONTHLY;     tolerance = 4;    // 28 to 31 days, and weekends.
        case .QUARTERLY;   tolerance = 8;
        case .YEARLY;      tolerance = 12;
    }
    period := cadence_days(c);
    if abs(gap - period) <= tolerance return 1;
    if c != .YEARLY && abs(gap - 2 * period) <= tolerance + tolerance / 2 return 2;
    return 0;
}

gap_fits :: (gap: s64, c: Cadence) -> bool { return gap_periods(gap, c) > 0; }

fit :: (charges: [] Charge, renewal: bool) -> Fit {
    result: Fit;
    days := occurrence_days(charges);
    if days.count < 2 return result;
    gaps := NewArray(days.count - 1, s64,, temp);
    for 0..gaps.count - 1 gaps[it] = days[it + 1] - days[it];
    typical := median(gaps);

    // The schedules whose window the typical gap falls in, tried in order;
    // the one most gaps fit wins, the first on a tie.
    WINDOWS :: s64.[5, 9,  11, 17,  26, 30,  26, 35,  80, 100,  345, 385];
    best_fits := -1;
    for ci: 0..cast(int) Cadence.YEARLY {
        c := cast(Cadence) ci;
        if typical < WINDOWS[ci * 2] || typical > WINDOWS[ci * 2 + 1] continue;
        fits, missed := 0, 0;
        for gaps {
            periods := gap_periods(it, c);
            if periods { fits += 1; missed += periods - 1; }
        }
        // Every 4 weeks keeps to 28 days, where monthly drifts between 28
        // and 31: only a run of four-weekly gaps, every one, is four-weekly.
        // It comes before monthly, so it wins when both fit them all.
        if c == .FOUR_WEEKLY && (fits < gaps.count || gaps.count < 2) continue;
        if fits <= best_fits continue;
        best_fits = fits;
        result.cadence = c;
        result.missed = missed;
    }
    if best_fits < 0 return result;
    // Two charges a year apart are a renewal only from a card on file or a debit.
    needed := ifx result.cadence == .YEARLY && renewal then 2 else 3;
    result.regular = days.count >= needed && best_fits * 4 >= gaps.count * 3 && result.missed * 3 <= gaps.count;
    return result;
}

// Charged by the merchant or the biller rather than bought each time: a
// card kept on file, a direct debit, BPAY.
renews :: (t: *Transaction) -> bool { return varies(t) || t.card_method == .CARD_ON_FILE; }

// Adds the series made of `charges` (oldest first) if they keep a schedule.
emit :: (out: *Recurring_State, s: *Store, charges: [] Charge, today: s64) {
    latest := *s.transactions[charges[charges.count - 1].index];
    f := fit(charges, renews(latest));
    if !f.regular return;

    first_day := charges[0].day;
    last_day := charges[charges.count - 1].day;
    period := cadence_days(f.cadence);

    // Next: on the usual day of the month (the median of the last three, or
    // the last one's when there are only two), or a period after the last.
    next_day := last_day + period;
    months := cadence_months(f.cadence);
    if months {
        days := occurrence_days(charges);
        day_of_month := cast(s64) civil_from_days(last_day).day;
        if days.count >= 3 {
            recent: [3] s64;
            for 0..2 recent[it] = civil_from_days(days[days.count - 1 - it]).day;
            day_of_month = median(recent);
        }
        month := month_key_from_day(last_day) + months;
        next_day = first_day_of_month(month) + min(day_of_month, days_in_month(month)) - 1;
    }
    active := today <= next_day + max(period / 2, 3);
    if !active && today - last_day > 400 return;   // Long over: not worth showing.

    series := array_add(*out.series);
    series.name = latest.description;
    series.cadence = f.cadence;
    series.missed = f.missed;
    series.account = latest.account;
    series.category = latest.category;
    series.first = out.members.count;
    series.count = charges.count;
    series.first_day = first_day;
    series.last_day = last_day;
    series.next_day = next_day;
    series.active = active;
    for charges array_add(*out.members, it.index);

    if latest.amount > 0 series.kind = .INCOME;
    else if category_is(s, latest.category, BILL_CATEGORIES) series.kind = .BILL;
    else if category_is(s, latest.category, SUBSCRIPTION_CATEGORIES) series.kind = .SUBSCRIPTION;
    else series.kind = ifx latest.card_method != .NONE then Recurring_Kind.SUBSCRIPTION else .BILL;

    // The amount: a run of prices (each but the newest seen at least twice)
    // is a fixed price that changed; anything else varies.
    series.low = charges[0].amount;
    series.high = charges[0].amount;
    for charges { series.low = min(series.low, it.amount); series.high = max(series.high, it.amount); }
    runs := 1;
    run_start := 0;
    steady := true;
    for i: 1..charges.count - 1 {
        if same_price(charges[i].amount, charges[run_start].amount) continue;
        if i - run_start < 2 steady = false;
        runs += 1;
        run_start = i;
    }
    expected: s64;
    if steady && runs <= 4 {
        expected = charges[charges.count - 1].amount;
        if runs > 1 {
            series.previous_amount = charges[run_start - 1].amount;
            series.changed_day = charges[run_start].day;
        }
    } else {
        series.variable = true;
        recent: [3] s64;
        n := min(charges.count, 3);
        for 0..n - 1 recent[it] = charges[charges.count - 1 - it].amount;
        expected = median(array_view(recent, 0, n));
    }
    series.amount = ifx latest.amount > 0 then expected else -expected;
    series.monthly = monthly_equivalent(expected, f.cadence);
}

same_price :: (a: s64, b: s64) -> bool { return abs(a - b) <= max(50, b / 50); }   // 50c or 2%.

// The middle value (the lower of the middle two).
median :: (values: [] s64) -> s64 {
    if !values.count return 0;
    sorted := NewArray(values.count, s64,, temp);
    memcpy(sorted.data, values.data, values.count * size_of(s64));
    for i: 1..sorted.count - 1 {
        j := i;
        while j > 0 && sorted[j - 1] > sorted[j] { sorted[j - 1], sorted[j] = sorted[j], sorted[j - 1]; j -= 1; }
    }
    return sorted[(sorted.count - 1) / 2];
}

BILL_CATEGORIES :: string.[
    "utilities", "internet", "mobile-phone", "rent-and-mortgage", "home-insurance-and-rates",
    "car-insurance-and-maintenance", "car-repayments", "health-and-medical", "education-and-student-loans", "life-admin",
];
SUBSCRIPTION_CATEGORIES :: string.[
    "tv-and-music", "apps-games-and-software", "news-magazines-and-books", "fitness-and-wellbeing",
];

category_is :: (s: *Store, category: s32, ids: [] string) -> bool {
    if category < 0 || category >= s.categories.count return false;
    for ids if s.categories[category].id == it return true;
    return false;
}

hash_text :: (text: string) -> u64 {
    h: u64 = 0xcbf29ce484222325;
    for 0..text.count - 1 { h ^= text[it]; h *= 0x100000001b3; }
    return h;
}
