// Sample data: an in-process stand-in for the Up API.
//
// It answers the same routes with the same JSON:API documents (paging
// links, filters, error documents, 204s for writes), so sample mode runs the
// real client, sync and parsing code. The data is generated once from a fixed
// seed: about two years of a plausible Melbourne customer - pay, rent, bills,
// savers and Round Ups, a joint 2Up account, a trip to Japan in yen - ending
// today, with the last day's card purchases still held.
//
// Runs on the network worker threads, under its own mutex.

demo_execute :: (method: string, full_path: string, body: string) -> Http_Result {
    lock(*demo_mutex);
    defer unlock(*demo_mutex);
    if !demo.ready demo_generate();

    // Network-ish latency, so loading states are real.
    sleep_milliseconds(cast(s32) rng_range(*demo.latency_rng, 70, 230));

    path, query := split_path_query(full_path);
    if begins_with(path, API_PREFIX) path = slice(path, API_PREFIX.count, path.count - API_PREFIX.count);
    params := parse_query(query);
    parts := split(path, "/",, temp);
    // parts[0] is empty: the path starts with '/'.
    if parts.count < 2 return error_result(404, "Not Found", "The resource does not exist.");
    p1 := parts[1];
    p2 := ifx parts.count > 2 then parts[2] else "";
    p3 := ifx parts.count > 3 then parts[3] else "";
    p4 := ifx parts.count > 4 then parts[4] else "";

    if method == "GET" {
        if p1 == "util" && p2 == "ping"       return ok_result(200, sprint("{\"meta\":{\"id\":\"%\",\"statusEmoji\":\"\\u26a1\\ufe0f\"}}", demo_uuid(*demo.rng)));
        if p1 == "accounts" && !p2.count      return list_accounts(params);
        if p1 == "accounts" && p3 == "transactions" return list_transactions(params, p2, path);
        if p1 == "accounts" && p2.count       return get_account(p2);
        if p1 == "categories" && !p2.count    return list_categories();
        if p1 == "tags"                       return list_tags(params);
        if p1 == "transactions" && !p2.count  return list_transactions(params, "", path);
        if p1 == "transactions" && p2.count   return get_transaction(p2);
        if p1 == "webhooks" && !p2.count      return list_webhooks();
        if p1 == "webhooks" && p3 == "logs"   return list_webhook_logs(p2, params, path);
        if p1 == "attachments" && p2.count    return get_attachment(p2);
    }
    if method == "PATCH" && p1 == "transactions" && p3 == "relationships" && p4 == "category" return set_category(p2, body);
    if (method == "POST" || method == "DELETE") && p1 == "transactions" && p3 == "relationships" && p4 == "tags" return change_tags(p2, body, method == "POST");
    if method == "POST" && p1 == "webhooks" && !p2.count       return create_webhook(body);
    if method == "POST" && p1 == "webhooks" && p3 == "ping"    return ping_webhook(p2);
    if method == "DELETE" && p1 == "webhooks" && p2.count      return delete_webhook(p2);
    return error_result(404, "Not Found", "The requested resource does not exist.");
}

demo_init :: () {
    init(*demo_mutex);
}

#scope_file

demo_mutex: Mutex;

Demo_Account :: struct {
    id:        string;
    name:      string;
    type:      string;   // TRANSACTIONAL / SAVER
    ownership: string;   // INDIVIDUAL / JOINT
    balance:   s64;
    created:   s64;      // UTC seconds
}

Demo_Txn :: struct {
    id:          string;
    account:     int;
    transfer:    int = -1;
    held:        bool;
    description: string;
    raw_text:    string;
    message:     string;
    note:        string;
    txn_type:    string;
    performer:   string;
    amount:      s64;
    has_hold:    bool;
    hold_amount: s64;
    round_up:    s64;
    boost:       s64;
    cashback:    s64;
    cashback_description: string;
    foreign_currency: string;
    foreign_value:    string;
    hold_foreign_value: string;
    card_method: string;
    card_suffix: string;
    created:     s64;
    settled:     s64;    // 0 while held
    category:    string;
    categorizable: bool;
    tags:        [..] string;
    attachment:  string;
}

Demo_Webhook :: struct {
    id: string;
    url: string;
    description: string;
    created: s64;
    healthy: bool;
}

Demo_Log :: struct {
    id: string;
    webhook: string;
    event_id: string;
    event_type: string;
    transaction: string;
    created: s64;
    status_code: s32;   // 0: undeliverable
}

Demo_State :: struct {
    ready: bool;
    rng: Rng;
    latency_rng: Rng;
    offset: s32;        // Local UTC offset, minutes.
    now: s64;
    today: s64;         // Local day number.
    accounts: [..] Demo_Account;
    txns: [..] Demo_Txn;           // Newest first once generated.
    webhooks: [..] Demo_Webhook;
    logs: [..] Demo_Log;           // Newest first.
    last_injection: s64;
}

demo: Demo_State;

//
// Random numbers (xorshift64*).
//

Rng :: struct { state: u64; }

rng_next :: (r: *Rng) -> u64 {
    x := r.state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    r.state = x;
    return x * 0x2545F4914F6CDD1D;
}

rng_float :: (r: *Rng) -> float64 { return cast(float64) (rng_next(r) >> 11) / cast(float64) (1 << 53); }
rng_range :: (r: *Rng, lo: s64, hi: s64) -> s64 { return lo + cast(s64) (rng_next(r) % cast(u64) (hi - lo + 1)); }
rng_chance :: (r: *Rng, p: float64) -> bool { return rng_float(r) < p; }

demo_uuid :: (r: *Rng) -> string {
    a := rng_next(r);
    b := rng_next(r);
    hex :: (v: u64, digits: int) -> string { return tprint("%", formatInt(v, base = 16, minimum_digits = digits)); }
    return sprint("%-%-4%-%-%",
        hex((a >> 32) & 0xFFFF_FFFF, 8), hex((a >> 16) & 0xFFFF, 4), hex(a & 0xFFF, 3),
        hex(0x8000 | ((b >> 48) & 0x3FFF), 4), hex(b & 0xFFFF_FFFF_FFFF, 12));
}

//
// Generation.
//

SPENDING :: 0;
JOINT    :: 1;
EMERGENCY:: 2;
BILLS    :: 3;
TRIP     :: 4;
HOUSE    :: 5;

Merchant :: struct {
    name:     string;
    raw:      string;
    category: string;
    lo, hi:   s64;      // Cents.
    per_month: float;
    joint:    bool;     // Usually bought from the 2Up account.
    online:   bool;
    hours:    [2] s32;  // Local hour range.
    weekend:  float = 1;
}

MERCHANTS :: Merchant.[
    .{"Woolworths",            "WOOLWORTHS 3352 RICHMOND",     "groceries",               1800, 16500, 7.0, true,  false, .[9, 20], 1},
    .{"Coles",                 "COLES 0614 CREMORNE",          "groceries",               1200, 9800,  4.0, true,  false, .[9, 21], 1},
    .{"Aldi",                  "ALDI STORES ABBOTSFORD",       "groceries",               1500, 7200,  2.0, false, false, .[10, 19], 1},
    .{"Harris Farm Markets",   "HARRIS FARM CAMBERWELL",       "groceries",               900,  4800,  1.2, true,  false, .[10, 18], 1.6},
    .{"Seven Seeds",           "SEVEN SEEDS CARLTON",          "restaurants-and-cafes",   450,  1400,  9.0, false, false, .[7, 11], 1},
    .{"Market Lane Coffee",    "MARKET LANE COFFEE PRAHRAN",   "restaurants-and-cafes",   450,  900,   6.0, false, false, .[7, 12], 1},
    .{"Higher Ground",         "HIGHER GROUND MELBOURNE",      "restaurants-and-cafes",   1800, 5600,  1.6, true,  false, .[9, 14], 2.2},
    .{"Lune Croissanterie",    "LUNE CROISSANTERIE FITZROY",   "restaurants-and-cafes",   650,  2600,  1.2, false, false, .[8, 13], 2.0},
    .{"Grill'd",               "GRILL'D SOUTHBANK",            "restaurants-and-cafes",   1650, 3200,  2.0, false, false, .[12, 20], 1},
    .{"Chin Chin",             "CHIN CHIN FLINDERS LANE",      "restaurants-and-cafes",   6400, 16800, 0.8, true,  false, .[18, 22], 2.0},
    .{"Tipo 00",               "TIPO 00 PTY LTD",              "restaurants-and-cafes",   7800, 18400, 0.5, true,  false, .[18, 22], 2.0},
    .{"Uber Eats",             "UBER *EATS HELP.UBER.COM",     "takeaway",                2400, 6200,  3.0, true,  true,  .[18, 22], 1.4},
    .{"Guzman y Gomez",        "GUZMAN Y GOMEZ COLLINS ST",    "takeaway",                1350, 2900,  2.2, false, false, .[11, 21], 1},
    .{"Domino's",              "DOMINOS PIZZA RICHMOND",       "takeaway",                1600, 4200,  0.8, true,  true,  .[18, 22], 1.8},
    .{"The Espy",              "THE ESPLANADE HOTEL STKILDA",  "pubs-and-bars",           1200, 6400,  1.2, false, false, .[17, 23], 2.5},
    .{"Bar Liberty",           "BAR LIBERTY FITZROY",          "pubs-and-bars",           1800, 8200,  0.9, false, false, .[18, 23], 2.5},
    .{"Dan Murphy's",          "DAN MURPHYS 4012 RICHMOND",    "booze",                   2200, 8900,  1.4, true,  false, .[15, 20], 1.6},
    .{"Myki",                  "PTV MYKI TOP UP",              "public-transport",        1000, 5000,  3.0, false, false, .[7, 9], 0.3},
    .{"Uber",                  "UBER *TRIP HELP.UBER.COM",     "taxis-and-share-cars",    1150, 4600,  2.2, false, true,  .[19, 24], 1.8},
    .{"DiDi",                  "DIDI MOBILITY AUSTRALIA",      "taxis-and-share-cars",    980,  3500,  0.8, false, true,  .[20, 24], 1.8},
    .{"Wilson Parking",        "WILSON PARKING QV",            "parking",                 800,  2800,  0.7, false, false, .[10, 20], 1},
    .{"7-Eleven",              "7-ELEVEN 2178 KEW",            "fuel",                    4200, 8900,  1.4, false, false, .[8, 20], 1},
    .{"Chemist Warehouse",     "CHEMIST WAREHOUSE BOURKE ST",  "health-and-medical",      690,  5400,  1.2, false, false, .[10, 19], 1},
    .{"Uniqlo",                "UNIQLO MELBOURNE CENTRAL",     "clothing-and-accessories", 2990, 11900, 0.6, false, false, .[11, 19], 1.8},
    .{"The Iconic",            "THE ICONIC SYDNEY",            "clothing-and-accessories", 5900, 18900, 0.35, false, true, .[20, 23], 1},
    .{"Kmart",                 "KMART BURWOOD",                "homeware-and-appliances", 1200, 7800,  0.9, true,  false, .[10, 19], 1.5},
    .{"IKEA",                  "IKEA RICHMOND",                "homeware-and-appliances", 3900, 29900, 0.2, true,  false, .[11, 18], 2.0},
    .{"Bunnings Warehouse",    "BUNNINGS HAWTHORN",            "home-maintenance-and-improvements", 1500, 12900, 0.5, true, false, .[9, 16], 2.2},
    .{"Officeworks",           "OFFICEWORKS RICHMOND",         "technology",              900,  8900,  0.5, false, false, .[10, 18], 1},
    .{"JB Hi-Fi",              "JB HI-FI MELBOURNE",           "technology",              2900, 39900, 0.2, false, false, .[11, 19], 1.4},
    .{"Readings",              "READINGS CARLTON",             "news-magazines-and-books", 2499, 6500, 0.5, false, false, .[11, 19], 1.6},
    .{"Steam",                 "STEAM PURCHASE BELLEVUE",      "apps-games-and-software", 1450, 8995,  0.3, false, true,  .[20, 24], 1.5},
    .{"Ticketek",              "TICKETEK AUSTRALIA",           "events-and-gigs",         6900, 21900, 0.25, false, true, .[12, 22], 1},
    .{"Rudy's Barbershop",     "RUDYS BARBERSHOP",             "hair-and-beauty",         3800, 4500,  0.8, false, false, .[10, 18], 1.5},
    .{"PETstock",              "PETSTOCK PRAHRAN",             "pets",                    2400, 9800,  0.6, true,  false, .[10, 17], 1.6},
    .{"SQ *Fitzroy Market",    "SQ *ROSE ST MARKET FITZROY",   "",                        800,  4500,  0.5, false, false, .[10, 15], 3.0},
];

Recurring :: struct {
    name:     string;
    raw:      string;
    category: string;
    amount:   s64;
    day_of_month: s32;
    method:   string;
    txn_type: string;
}

MONTHLY :: Recurring.[
    .{"Spotify",          "SPOTIFY P2D4F8E1A2 STOCKHOLM", "tv-and-music",            1399,  3,  "CARD_ON_FILE", "Purchase"},
    .{"Apple",            "APPLE.COM/BILL SYDNEY",        "apps-games-and-software", 449,   5,  "CARD_ON_FILE", "Purchase"},
    .{"Netflix",          "NETFLIX.COM MELBOURNE",        "tv-and-music",            1899,  8,  "CARD_ON_FILE", "Purchase"},
    .{"Aussie Broadband", "AUSSIE BROADBAND MORWELL",     "internet",                8900,  12, "CARD_ON_FILE", "Purchase"},
    .{"Belong",           "BELONG MOBILE MELBOURNE",      "mobile-phone",            3500,  20, "CARD_ON_FILE", "Purchase"},
    .{"Bupa",             "BUPA HEALTH INSURANCE",        "health-and-medical",      15120, 25, "",             "Direct Debit"},
    .{"Strava",           "STRAVA INC SAN FRANCISCO",     "fitness-and-wellbeing",   1199,  17, "CARD_ON_FILE", "Purchase"},
];

FRIENDS :: string.["Priya Nair", "Ben Okafor", "Mia Rossi", "Tom Nguyen"];
FRIEND_MESSAGES_IN  :: string.["Dinner \xf0\x9f\x8d\x9c", "Uber home", "Concert tickets", "Thanks for Friday!", "Bills split", "Birthday gift share", "Footy tix"];
FRIEND_MESSAGES_OUT :: string.["My half of dinner", "Gift for Mia", "Pizza night", "Tickets", "Brunch \xe2\x98\x95"];

Trip_Place :: struct { name: string; raw: string; category: string; yen_lo: s64; yen_hi: s64; }
TRIP_PLACES :: Trip_Place.[
    .{"Lawson",          "LAWSON SHIBUYA TOKYO",        "groceries",               380,   1800},
    .{"FamilyMart",      "FAMILYMART SHINJUKU",         "groceries",               260,   1400},
    .{"Ichiran",         "ICHIRAN SHIBUYA",             "restaurants-and-cafes",   1180,  2600},
    .{"Blue Bottle Coffee", "BLUE BOTTLE KIYOSUMI",     "restaurants-and-cafes",   650,   1500},
    .{"JR East",         "JR EAST SUICA TOKYO",         "public-transport",        2000,  5000},
    .{"Don Quijote",     "DON QUIJOTE SHIBUYA",         "homeware-and-appliances", 1800,  9800},
    .{"Uniqlo Ginza",    "UNIQLO GINZA TOKYO",          "clothing-and-accessories", 2990, 12900},
    .{"Tsukiji Outer Market", "TSUKIJI SUSHI TOKYO",    "restaurants-and-cafes",   2400,  7800},
    .{"Kyoto Bus",       "KYOTO CITY BUS",              "public-transport",        230,   1200},
    .{"Nishiki Market",  "NISHIKI MARKET KYOTO",        "restaurants-and-cafes",   900,   4200},
];

YEN_TO_CENTS :: 1.03;   // ~ 0.0103 AUD per yen.

g_balances: [6] s64;

demo_generate :: () {
    demo.rng.state = 0x9E3779B97F4A7C15;
    demo.latency_rng.state = 0xD1B54A32D192ED03;
    lt := platform_local_time();
    demo.offset = lt.offset_minutes;
    demo.now = lt.utc_seconds;
    demo.today = floor_div(demo.now + demo.offset * 60, SECONDS_PER_DAY);
    r := *demo.rng;

    DAYS :: 790;
    start := demo.today - DAYS;
    local_midnight_utc :: (day: s64) -> s64 { return day * SECONDS_PER_DAY - demo.offset * 60; }

    add_account :: (name: string, type: string, own: string, opening: s64, created_day: s64) {
        a := array_add(*demo.accounts);
        a.id = demo_uuid(*demo.rng);
        a.name = name;
        a.type = type;
        a.ownership = own;
        a.created = local_midnight_utc(created_day) + 10 * 3600;
        g_balances[demo.accounts.count - 1] = opening;
    }
    add_account("Spending",         "TRANSACTIONAL", "INDIVIDUAL", 185000,  start - 410);
    add_account("2Up Spending",     "TRANSACTIONAL", "JOINT",      0,       start + 210);
    add_account("Emergency Fund",   "SAVER",         "INDIVIDUAL", 400000,  start - 380);
    add_account("Bills",            "SAVER",         "INDIVIDUAL", 45000,   start - 300);
    add_account("\xe2\x9c\x88\xef\xb8\x8f Japan 2026", "SAVER", "INDIVIDUAL", 0, start + 40);
    add_account("House Deposit",    "SAVER",         "INDIVIDUAL", 1450000, start - 400);

    joint_open := start + 210;
    round_up_start := start + 120;
    trip_start := demo.today - 132;
    trip_end   := trip_start + 11;
    salary := 328450;

    for day: start..demo.today {
        midnight := local_midnight_utc(day);
        date := civil_from_days(day);
        weekday := weekday_from_days(day);
        is_weekend := weekday >= 5;
        months_in := (day - start) / 30;
        is_last_day := civil_from_days(day + 1).day == 1;
        on_trip := day >= trip_start && day <= trip_end;


        // Pay day, and the automatic transfers that follow it.
        if (day - start) % 14 == 3 {
            if months_in == 13 && salary == 328450 salary = 341280;   // A pay rise.
            t := income(SPENDING, "ACME Logistics", "ACME LOGISTICS PTY LTD SALARY", salary, at(midnight, 3, 12), "Salary");
            t.txn_type = "Direct Credit";
            transfer(SPENDING, BILLS, 24000, at(midnight, 6, 30));
            transfer(SPENDING, EMERGENCY, 25000, at(midnight, 6, 31));
            if day >= start + 40 && day < trip_start transfer(SPENDING, TRIP, 15000, at(midnight, 6, 32));
        }
        if date.day == 15 transfer(SPENDING, HOUSE, 145000, at(midnight, 6, 40));
        // Bills covers the monthly direct debits.
        if date.day == 24 transfer(BILLS, SPENDING, 33000, at(midnight, 7, 15));

        // Rent, monthly.
        if date.day == 1 {
            purchase(SPENDING, "Ray White Richmond", "BPAY RAY WHITE RICHMOND 2235", "rent-and-mortgage", 235000, at(midnight, 9, 5), "", "BPAY Payment");
        }

        // Subscriptions.
        for MONTHLY {
            if date.day != it.day_of_month continue;
            t := purchase(SPENDING, it.name, it.raw, it.category, it.amount, at(midnight, 4, 20), it.method, it.txn_type);
            if t && it.name == "Spotify" && months_in > 14 { g_balances[SPENDING] += t.amount + 1499; t.amount = -1499; }
        }
        if (day - start) % 14 == 9 purchase(SPENDING, "Anytime Fitness", "ANYTIME FITNESS RICHMOND", "fitness-and-wellbeing", 3295, at(midnight, 5, 0), "", "Direct Debit");

        // Quarterly bills, paid from Spending after a top-up from Bills.
        if (date.month % 3 == 1) && date.day == 18 {
            amount := rng_range(r, 23800, 34200);
            transfer(BILLS, SPENDING, amount, at(midnight, 8, 2));
            purchase(SPENDING, "AGL", "AGL ENERGY MELBOURNE", "utilities", amount, at(midnight, 8, 10), "", "BPAY Payment");
        }
        if (date.month % 3 == 2) && date.day == 22 {
            amount := rng_range(r, 15800, 21400);
            transfer(BILLS, SPENDING, amount, at(midnight, 8, 2));
            purchase(SPENDING, "Yarra Valley Water", "YARRA VALLEY WATER", "utilities", amount, at(midnight, 8, 10), "", "BPAY Payment");
        }

        // The joint account: weekly contributions from both owners.
        if day >= joint_open && weekday == 1 {
            transfer(SPENDING, JOINT, 15000, at(midnight, 7, 0));
            t := income(JOINT, "Alex Morgan", "", 15000, at(midnight, 7, 5), "");
            t.performer = "Alex";
            t.txn_type = "Transfer";
            t.message = "Weekly 2Up";
        }

        // Everyday spending.
        if !on_trip {
            for m: MERCHANTS {
                p := m.per_month / 30.0;
                if is_weekend p *= m.weekend;
                if !rng_chance(r, p) continue;
                account := SPENDING;
                if m.joint && day >= joint_open && rng_chance(r, 0.75) account = JOINT;
                cents := rng_range(r, m.lo, m.hi);
                if m.category == "restaurants-and-cafes" && m.hi < 1500 cents = (cents / 50) * 50;   // Coffee prices.
                hour := rng_range(r, m.hours[0], m.hours[1] - 1);
                t := purchase(account, m.name, m.raw, m.category, cents, at(midnight, hour, rng_range(r, 0, 50)), ifx m.online then "ECOMMERCE" else "", "Purchase");
                if !t continue;
                if account == JOINT t.performer = ifx rng_chance(r, 0.5) then "Alex" else "Jordan";
                if (m.name == "Chin Chin" || m.name == "Tipo 00") && rng_chance(r, 0.6) array_add(*t.tags, "Date night");
                if (m.name == "Officeworks" || m.name == "Uber") && rng_chance(r, 0.15) {
                    array_add(*t.tags, "Work expense");
                    if rng_chance(r, 0.5) t.attachment = demo_uuid(r);
                }
                if m.name == "JB Hi-Fi" && rng_chance(r, 0.4) {
                    array_add(*t.tags, "Tax deductible");
                    t.attachment = demo_uuid(r);
                }
                if m.name == "7-Eleven" { t.has_hold = true; t.hold_amount = -15000; }   // Fuel pre-authorisation.
                if m.category == "takeaway" && rng_chance(r, 0.08) t.note = "Split with Alex";
            }
        } else {
            for 0..rng_range(r, 3, 7) {
                s := TRIP_PLACES[rng_range(r, 0, TRIP_PLACES.count - 1)];
                yen := rng_range(r, s.yen_lo, s.yen_hi);
                yen = (yen / 10) * 10;
                cents := cast(s64) (yen * YEN_TO_CENTS);
                // Tokyo is UTC+9.
                t := purchase(SPENDING, s.name, s.raw, s.category, cents, at(midnight, rng_range(r, 0, 12), rng_range(r, 0, 59)), "CONTACTLESS", "Purchase");
                if !t continue;
                t.foreign_currency = "JPY";
                t.foreign_value = tprint("-%", yen);
                t.foreign_value = copy_string(t.foreign_value);
                array_add(*t.tags, "Japan 2026");
            }
        }

        // Booking the trip.
        if day == trip_start - 160 {
            t := purchase(SPENDING, "Qantas", "QANTAS AIRWAYS MASCOT", "holidays-and-travel", 148640, at(midnight, 21, 14), "ECOMMERCE", "Purchase");
            if t array_add(*t.tags, "Japan 2026");
        }
        if day == trip_start - 120 {
            t := purchase(SPENDING, "Booking.com", "BOOKING.COM AMSTERDAM", "holidays-and-travel", 112000, at(midnight, 22, 3), "ECOMMERCE", "Purchase");
            if t { array_add(*t.tags, "Japan 2026"); t.note = "Kyoto ryokan, 3 nights"; }
        }
        if day == trip_start - 1 transfer(TRIP, SPENDING, g_balances[TRIP] - 15000, at(midnight, 9, 0));

        // Friends settling up.
        if rng_chance(r, 0.10) {
            who := FRIENDS[rng_range(r, 0, FRIENDS.count - 1)];
            t := income(SPENDING, who, "", rng_range(r, 18, 85) * 100, at(midnight, rng_range(r, 9, 21), 0), "");
            t.message = FRIEND_MESSAGES_IN[rng_range(r, 0, FRIEND_MESSAGES_IN.count - 1)];
            t.txn_type = "Osko Payment Received";
        }
        if rng_chance(r, 0.05) {
            who := FRIENDS[rng_range(r, 0, FRIENDS.count - 1)];
            t := purchase(SPENDING, who, "", "", rng_range(r, 15, 90) * 100, at(midnight, rng_range(r, 9, 21), 0), "", "Pay Anyone");
            if t {
                t.message = FRIEND_MESSAGES_OUT[rng_range(r, 0, FRIEND_MESSAGES_OUT.count - 1)];
                t.categorizable = false;
                t.category = "";
            }
        }

        // Cashback, now and then.
        if rng_chance(r, 0.006) {
            t := income(SPENDING, "Cashback", "", 500, at(midnight, 10, 0), "");
            t.cashback = 500;
            t.cashback_description = "Up Cashback: Spotify Premium promotion";
            t.txn_type = "Cashback";
        }

        // Interest on savers, on the last day of the month.
        if is_last_day {
            for acct: EMERGENCY..HOUSE {
                interest := cast(s64) (g_balances[acct] * 0.0510 / 12.0);
                if interest <= 0 continue;
                t := income(acct, "Interest", "", interest, local_midnight_utc(day) + 23 * 3600 + 30 * 60, "");
                t.txn_type = "Interest";
            }
        }
    }

    // Purchases from the last day and a half are still held.
    for * demo.txns {
        if it.card_method.count && demo.now - it.created < 36 * 3600 {
            it.held = true;
            it.settled = 0;
            it.has_hold = true;
            if it.hold_amount == 0 it.hold_amount = it.amount;
            else it.amount = it.hold_amount;   // Still at the pre-authorised amount.
            if it.foreign_value.count it.hold_foreign_value = it.foreign_value;
        }
    }

    sort_txns();
    for * demo.accounts it.balance = g_balances[it_index];

    // Webhooks with a delivery history.
    add_webhook :: (url: string, description: string, created: s64, healthy: bool) {
        w := array_add(*demo.webhooks);
        w.id = demo_uuid(*demo.rng);
        w.url = url;
        w.description = description;
        w.created = created;
        w.healthy = healthy;
    }
    add_webhook("https://budget.example.net/hooks/up", "Budget sync", demo.now - 400 * SECONDS_PER_DAY, true);
    add_webhook("https://home.example.dev/up-events", "Home dashboard", demo.now - 90 * SECONDS_PER_DAY, false);
    for w: demo.webhooks {
        count := 0;
        for t: demo.txns {
            if t.created < w.created continue;
            if count >= 160 break;
            count += 1;
            status: s32 = 200;
            if !w.healthy {
                roll := rng_float(r);
                if roll < 0.10 status = 0;
                else if roll < 0.22 status = 502;
            }
            log := array_add(*demo.logs);
            log.id = demo_uuid(r);
            log.webhook = w.id;
            log.event_id = demo_uuid(r);
            log.event_type = ifx t.held then "TRANSACTION_CREATED" else ifx rng_chance(r, 0.5) then "TRANSACTION_SETTLED" else "TRANSACTION_CREATED";
            log.transaction = t.id;
            log.created = t.created + rng_range(r, 1, 4);
            log.status_code = status;
        }
    }
    sort_logs();
    demo.last_injection = demo.now;
    demo.ready = true;
}

sort_txns :: () {
    quick_sort(demo.txns, (a: Demo_Txn, b: Demo_Txn) -> int {
        if a.created != b.created return ifx a.created > b.created then -1 else 1;
        return compare_strings(a.id, b.id);
    });
}

sort_logs :: () {
    quick_sort(demo.logs, (a: Demo_Log, b: Demo_Log) -> int {
        if a.created != b.created return ifx a.created > b.created then -1 else 1;
        return compare_strings(a.id, b.id);
    });
}

// A time on the local day starting at `midnight`, with random seconds.
at :: (midnight: s64, h: s64, m: s64) -> s64 {
    return midnight + h * 3600 + m * 60 + rng_range(*demo.rng, 0, 59);
}

new_txn :: (account: int, created: s64) -> *Demo_Txn {
    t := array_add(*demo.txns);
    t.id = demo_uuid(*demo.rng);
    t.account = account;
    t.created = created;
    t.settled = created;
    return t;
}

income :: (account: int, description: string, raw: string, cents: s64, created: s64, message: string) -> *Demo_Txn {
    t := new_txn(account, created);
    t.description = description;
    t.raw_text = raw;
    t.message = message;
    t.amount = cents;
    g_balances[account] += cents;
    return t;
}

purchase :: (account: int, description: string, raw: string, category: string, cents: s64, created: s64, method: string, txn_type: string) -> *Demo_Txn {
    if created > demo.now return null;
    if g_balances[account] - cents < 2500 return null;   // Declined, near enough.
    r := *demo.rng;
    t := new_txn(account, created);
    t.description = description;
    t.raw_text = raw;
    t.amount = -cents;
    t.category = category;
    t.categorizable = true;
    t.txn_type = txn_type;
    is_card := txn_type == "Purchase";
    if is_card {
        t.card_method = ifx method.count then method else ifx rng_chance(r, 0.9) then "CONTACTLESS" else "CARD_PIN";
        t.card_suffix = ifx account == JOINT then "7710" else "4821";
        t.settled = created + rng_range(r, 20 * 3600, 70 * 3600);
        if t.settled > demo.now t.settled = demo.now - 60;
    }
    g_balances[account] -= cents;

    // Round Ups from Spending card purchases, swept to the trip saver.
    if is_card && account == SPENDING && created >= demo.now - 670 * SECONDS_PER_DAY {
        up := (100 - cents % 100) % 100;
        boost: s64 = ifx rng_chance(r, 0.07) then 100 else 0;
        total := up + boost;
        if total > 0 && g_balances[SPENDING] - total > 0 {
            t.round_up = -total;
            t.boost = -boost;
            g_balances[SPENDING] -= total;
            ru := new_txn(TRIP, created + 1);
            ru.description = "Round Up";
            ru.amount = total;
            ru.transfer = SPENDING;
            ru.txn_type = "Round Up";
            g_balances[TRIP] += total;
        }
    }
    return t;
}

transfer :: (from: int, to: int, cents: s64, created: s64) {
    if cents <= 0 || g_balances[from] < cents return;
    out := new_txn(from, created);
    out.description = tprint("Transfer to %", demo.accounts[to].name);
    out.description = copy_string(out.description);
    out.amount = -cents;
    out.transfer = to;
    out.txn_type = "Transfer";
    g_balances[from] -= cents;
    in := new_txn(to, created);
    in.description = tprint("Transfer from %", demo.accounts[from].name);
    in.description = copy_string(in.description);
    in.amount = cents;
    in.transfer = from;
    in.txn_type = "Transfer";
    g_balances[to] += cents;
}

// A refresh now and then finds something new: a coffee, still held.
maybe_inject :: () {
    lt := platform_local_time();
    if lt.utc_seconds - demo.last_injection < 40 return;
    demo.last_injection = lt.utc_seconds;
    demo.now = lt.utc_seconds;
    r := *demo.rng;
    spots := string.["Seven Seeds", "Market Lane Coffee", "Lune Croissanterie"];
    raws  := string.["SEVEN SEEDS CARLTON", "MARKET LANE COFFEE PRAHRAN", "LUNE CROISSANTERIE FITZROY"];
    pick := rng_range(r, 0, 2);
    for * demo.accounts g_balances[it_index] = it.balance;
    t := purchase(SPENDING, spots[pick], raws[pick], "restaurants-and-cafes", rng_range(r, 9, 26) * 50, lt.utc_seconds - 5, "CONTACTLESS", "Purchase");
    if t {
        t.held = true;
        t.settled = 0;
        t.has_hold = true;
        t.hold_amount = t.amount;
    }
    sort_txns();
    for * demo.accounts it.balance = g_balances[it_index];
}

//
// Responses.
//

ok_result :: (status: s32, body: string) -> Http_Result {
    result: Http_Result;
    result.status = status;
    result.body = body;
    return result;
}

error_result :: (status: s32, title: string, detail: string) -> Http_Result {
    return ok_result(status, sprint("{\"errors\":[{\"status\":\"%\",\"title\":\"%\",\"detail\":\"%\"}]}", status, json_escape(title), json_escape(detail)));
}

split_path_query :: (full: string) -> string, string {
    found, path, query := split_from_left(full, "?");
    if !found return full, "";
    return path, query;
}

Param :: struct { name: string; value: string; }

parse_query :: (query: string) -> [] Param {
    params: [..] Param;
    params.allocator = temp;
    if !query.count return params;
    for part: split(query, "&",, temp) {
        found, name, value := split_from_left(part, "=");
        array_add(*params, .{url_decode(name), url_decode(value)});
    }
    return params;
}

param :: (params: [] Param, name: string) -> string {
    for params if it.name == name return it.value;
    return "";
}

url_decode :: (s: string) -> string {
    builder: String_Builder;
    builder.allocator = temp;
    i := 0;
    while i < s.count {
        c := s[i];
        if c == #char "%" && i + 2 < s.count + 0 && i + 2 <= s.count - 1 {
            hex := slice(s, i + 1, 2);
            v, ok := string_to_int(hex, 16);
            if ok { append(*builder, cast(u8) v); i += 3; continue; }
        }
        append(*builder, ifx c == #char "+" then cast(u8) #char " " else c);
        i += 1;
    }
    return builder_to_string(*builder,, temp);
}

money_json :: (builder: *String_Builder, cents: s64) {
    sign := ifx cents < 0 then "-" else "";
    v := abs(cents);
    print_to_builder(builder, "{\"currencyCode\":\"AUD\",\"value\":\"%1%2.%3\",\"valueInBaseUnits\":%4}", sign, v / 100, pad2(v % 100), cents);
}

time_json :: (utc: s64) -> string {
    local := utc + demo.offset * 60;
    day := floor_div(local, SECONDS_PER_DAY);
    secs := local - day * SECONDS_PER_DAY;
    d := civil_from_days(day);
    o := abs(demo.offset);
    return tprint("%-%-%T%:%:%%%:%", d.year, pad2(d.month), pad2(d.day), pad2(secs / 3600), pad2((secs / 60) % 60), pad2(secs % 60),
                  ifx demo.offset < 0 then "-" else "+", pad2(o / 60), pad2(o % 60));
}

str_or_null :: (s: string) -> string {
    if !s.count return "null";
    return tprint("\"%\"", json_escape(s));
}

parent_of :: (category: string) -> string {
    for CATEGORIES if it.id == category return it.parent;
    return "";
}

txn_json :: (b: *String_Builder, t: *Demo_Txn) {
    print_to_builder(b, "{\"type\":\"transactions\",\"id\":\"%\",\"attributes\":{", t.id);
    print_to_builder(b, "\"status\":\"%\",", ifx t.held then "HELD" else "SETTLED");
    print_to_builder(b, "\"rawText\":%,\"description\":%,\"message\":%,", str_or_null(t.raw_text), str_or_null(t.description), str_or_null(t.message));
    print_to_builder(b, "\"isCategorizable\":%,", ifx t.categorizable then "true" else "false");
    if t.has_hold {
        append(b, "\"holdInfo\":{\"amount\":");
        money_json(b, t.hold_amount);
        if t.hold_foreign_value.count print_to_builder(b, ",\"foreignAmount\":{\"currencyCode\":\"%\",\"value\":\"%\",\"valueInBaseUnits\":0}", t.foreign_currency, t.hold_foreign_value);
        else append(b, ",\"foreignAmount\":null");
        append(b, "},");
    } else {
        append(b, "\"holdInfo\":null,");
    }
    if t.round_up {
        append(b, "\"roundUp\":{\"amount\":");
        money_json(b, t.round_up);
        append(b, ",\"boostPortion\":");
        if t.boost money_json(b, t.boost); else append(b, "null");
        append(b, "},");
    } else {
        append(b, "\"roundUp\":null,");
    }
    if t.cashback {
        print_to_builder(b, "\"cashback\":{\"description\":%,\"amount\":", str_or_null(t.cashback_description));
        money_json(b, t.cashback);
        append(b, "},");
    } else {
        append(b, "\"cashback\":null,");
    }
    append(b, "\"amount\":");
    money_json(b, t.amount);
    append(b, ",");
    if t.foreign_value.count {
        digits := t.foreign_value;
        if digits.count && digits[0] == #char "-" advance(*digits, 1);
        print_to_builder(b, "\"foreignAmount\":{\"currencyCode\":\"%\",\"value\":\"%\",\"valueInBaseUnits\":-%},", t.foreign_currency, t.foreign_value, digits);
    } else {
        append(b, "\"foreignAmount\":null,");
    }
    if t.card_method.count print_to_builder(b, "\"cardPurchaseMethod\":{\"method\":\"%\",\"cardNumberSuffix\":%},", t.card_method, str_or_null(t.card_suffix));
    else append(b, "\"cardPurchaseMethod\":null,");
    print_to_builder(b, "\"settledAt\":%,", ifx t.settled then tprint("\"%\"", time_json(t.settled)) else "null");
    print_to_builder(b, "\"createdAt\":\"%\",", time_json(t.created));
    print_to_builder(b, "\"transactionType\":%,", str_or_null(t.txn_type));
    print_to_builder(b, "\"note\":%,", ifx t.note.count then tprint("{\"text\":%}", str_or_null(t.note)) else "null");
    print_to_builder(b, "\"performingCustomer\":%", tprint("{\"displayName\":\"%\"}", ifx t.performer.count then t.performer else "Jordan"));
    append(b, "},\"relationships\":{");
    print_to_builder(b, "\"account\":{\"data\":{\"type\":\"accounts\",\"id\":\"%\"}},", demo.accounts[t.account].id);
    if t.transfer >= 0 print_to_builder(b, "\"transferAccount\":{\"data\":{\"type\":\"accounts\",\"id\":\"%\"}},", demo.accounts[t.transfer].id);
    else append(b, "\"transferAccount\":{\"data\":null},");
    if t.category.count {
        print_to_builder(b, "\"category\":{\"data\":{\"type\":\"categories\",\"id\":\"%\"}},", t.category);
        print_to_builder(b, "\"parentCategory\":{\"data\":{\"type\":\"categories\",\"id\":\"%\"}},", parent_of(t.category));
    } else {
        append(b, "\"category\":{\"data\":null},\"parentCategory\":{\"data\":null},");
    }
    append(b, "\"tags\":{\"data\":[");
    for t.tags {
        if it_index append(b, ",");
        print_to_builder(b, "{\"type\":\"tags\",\"id\":\"%\"}", json_escape(it));
    }
    append(b, "]},");
    if t.attachment.count print_to_builder(b, "\"attachment\":{\"data\":{\"type\":\"attachments\",\"id\":\"%\"}}", t.attachment);
    else append(b, "\"attachment\":{\"data\":null}");
    append(b, "}}");
}

// Paging: page[after] is an offset; the next link keeps every other parameter.
page_links :: (b: *String_Builder, path: string, params: [] Param, next_offset: int, more: bool) {
    append(b, ",\"links\":{\"prev\":null,\"next\":");
    if more {
        print_to_builder(b, "\"https://api.up.com.au%1%2?%3=%4", API_PREFIX, path, url_encode("page[after]"), next_offset);
        for params {
            if it.name == "page[after]" continue;
            print_to_builder(b, "&%=%", url_encode(it.name), url_encode(it.value));
        }
        append(b, "\"");
    } else {
        append(b, "null");
    }
    append(b, "}");
}

page_size :: (params: [] Param) -> int {
    size, ok := string_to_int(param(params, "page[size]"));
    if !ok || size <= 0 return 10;
    return min(size, 100);
}

list_accounts :: (params: [] Param) -> Http_Result {
    b: String_Builder;
    append(*b, "{\"data\":[");
    for demo.accounts {
        if it_index append(*b, ",");
        account_json(*b, *it);
    }
    append(*b, "],\"links\":{\"prev\":null,\"next\":null}}");
    return ok_result(200, builder_to_string(*b));
}

account_json :: (b: *String_Builder, a: *Demo_Account) {
    print_to_builder(b, "{\"type\":\"accounts\",\"id\":\"%\",\"attributes\":{\"displayName\":\"%\",\"accountType\":\"%\",\"ownershipType\":\"%\",\"balance\":", a.id, json_escape(a.name), a.type, a.ownership);
    money_json(b, a.balance);
    print_to_builder(b, ",\"createdAt\":\"%\"},\"relationships\":{\"transactions\":{}}}", time_json(a.created));
}

get_account :: (id: string) -> Http_Result {
    for * demo.accounts {
        if it.id != id continue;
        b: String_Builder;
        append(*b, "{\"data\":");
        account_json(*b, it);
        append(*b, "}");
        return ok_result(200, builder_to_string(*b));
    }
    return error_result(404, "Not Found", "The account does not exist.");
}

Category_Def :: struct { id: string; name: string; parent: string; }

CATEGORIES :: Category_Def.[
    .{"good-life", "Good Life", ""},
    .{"personal", "Personal", ""},
    .{"home", "Home", ""},
    .{"transport", "Transport", ""},
    .{"apps-games-and-software", "Apps, Games & Software", "good-life"},
    .{"booze", "Booze", "good-life"},
    .{"events-and-gigs", "Events & Gigs", "good-life"},
    .{"hobbies", "Hobbies", "good-life"},
    .{"holidays-and-travel", "Holidays & Travel", "good-life"},
    .{"lottery-and-gambling", "Lottery & Gambling", "good-life"},
    .{"pubs-and-bars", "Pubs & Bars", "good-life"},
    .{"restaurants-and-cafes", "Restaurants & Cafes", "good-life"},
    .{"takeaway", "Takeaway", "good-life"},
    .{"tobacco-and-vaping", "Tobacco & Vaping", "good-life"},
    .{"tv-and-music", "TV, Music & Streaming", "good-life"},
    .{"adult", "Adult", "good-life"},
    .{"children-and-family", "Children & Family", "personal"},
    .{"clothing-and-accessories", "Clothing & Accessories", "personal"},
    .{"education-and-student-loans", "Education & Student Loans", "personal"},
    .{"fitness-and-wellbeing", "Fitness & Wellbeing", "personal"},
    .{"gifts-and-charity", "Gifts & Charity", "personal"},
    .{"hair-and-beauty", "Hair & Beauty", "personal"},
    .{"health-and-medical", "Health & Medical", "personal"},
    .{"investments", "Investments", "personal"},
    .{"life-admin", "Life Admin", "personal"},
    .{"mobile-phone", "Mobile Phone", "personal"},
    .{"news-magazines-and-books", "News, Magazines & Books", "personal"},
    .{"technology", "Technology", "personal"},
    .{"groceries", "Groceries", "home"},
    .{"homeware-and-appliances", "Homeware & Appliances", "home"},
    .{"internet", "Internet", "home"},
    .{"home-maintenance-and-improvements", "Maintenance & Improvements", "home"},
    .{"pets", "Pets", "home"},
    .{"home-insurance-and-rates", "Rates & Insurance", "home"},
    .{"rent-and-mortgage", "Rent & Mortgage", "home"},
    .{"utilities", "Utilities", "home"},
    .{"car-insurance-and-maintenance", "Car Insurance, Rego & Maintenance", "transport"},
    .{"cycling", "Cycling", "transport"},
    .{"fuel", "Fuel", "transport"},
    .{"parking", "Parking", "transport"},
    .{"public-transport", "Public Transport", "transport"},
    .{"car-repayments", "Repayments", "transport"},
    .{"taxis-and-share-cars", "Taxis & Share Cars", "transport"},
    .{"toll-roads", "Tolls", "transport"},
];

list_categories :: () -> Http_Result {
    b: String_Builder;
    append(*b, "{\"data\":[");
    for c: CATEGORIES {
        if it_index append(*b, ",");
        print_to_builder(*b, "{\"type\":\"categories\",\"id\":\"%\",\"attributes\":{\"name\":\"%\"},\"relationships\":{\"parent\":{\"data\":%},\"children\":{\"data\":[",
            c.id, json_escape(c.name), ifx c.parent.count then tprint("{\"type\":\"categories\",\"id\":\"%\"}", c.parent) else "null");
        first := true;
        for child: CATEGORIES {
            if child.parent != c.id continue;
            if !first append(*b, ",");
            first = false;
            print_to_builder(*b, "{\"type\":\"categories\",\"id\":\"%\"}", child.id);
        }
        append(*b, "]}}}");
    }
    append(*b, "]}");
    return ok_result(200, builder_to_string(*b));
}

list_tags :: (params: [] Param) -> Http_Result {
    labels: [..] string;
    labels.allocator = temp;
    for t: demo.txns for tag: t.tags {
        found := false;
        for labels if it == tag { found = true; break; }
        if !found array_add(*labels, tag);
    }
    quick_sort(labels, compare_strings);
    b: String_Builder;
    append(*b, "{\"data\":[");
    for labels {
        if it_index append(*b, ",");
        print_to_builder(*b, "{\"type\":\"tags\",\"id\":\"%\",\"relationships\":{\"transactions\":{}}}", json_escape(it));
    }
    append(*b, "],\"links\":{\"prev\":null,\"next\":null}}");
    return ok_result(200, builder_to_string(*b));
}

list_transactions :: (params: [] Param, account_id: string, path: string) -> Http_Result {
    since_text := param(params, "filter[since]");
    until_text := param(params, "filter[until]");
    status := param(params, "filter[status]");
    category := param(params, "filter[category]");
    tag := param(params, "filter[tag]");
    since, has_since := parse_rfc3339(since_text);
    until, has_until := parse_rfc3339(until_text);
    if since_text.count && !has_since return error_result(400, "Invalid Parameter", "filter[since] must be an RFC-3339 date-time.");
    if category.count {
        known := false;
        for CATEGORIES if it.id == category known = true;
        if !known return error_result(404, "Not Found", "The category does not exist.");
    }
    account := -1;
    if account_id.count {
        for demo.accounts if it.id == account_id account = it_index;
        if account < 0 return error_result(404, "Not Found", "The account does not exist.");
    }
    if has_since && !param(params, "page[after]").count maybe_inject();

    offset, _ := string_to_int(param(params, "page[after]"));
    size := page_size(params);
    b: String_Builder;
    append(*b, "{\"data\":[");
    matched := 0;
    written := 0;
    more := false;
    for * t: demo.txns {
        if account >= 0 && t.account != account continue;
        if has_since && t.created < since.utc continue;
        if has_until && t.created >= until.utc continue;
        if status == "HELD" && !t.held continue;
        if status == "SETTLED" && t.held continue;
        if category.count && t.category != category && parent_of(t.category) != category continue;
        if tag.count {
            found := false;
            for t.tags if it == tag found = true;
            if !found continue;
        }
        matched += 1;
        if matched <= offset continue;
        if written == size { more = true; break; }
        if written append(*b, ",");
        txn_json(*b, t);
        written += 1;
    }
    append(*b, "]");
    page_links(*b, path, params, offset + written, more);
    append(*b, "}");
    return ok_result(200, builder_to_string(*b));
}

find_txn :: (id: string) -> *Demo_Txn {
    for * demo.txns if it.id == id return it;
    return null;
}

get_transaction :: (id: string) -> Http_Result {
    t := find_txn(id);
    if !t return error_result(404, "Not Found", "The transaction does not exist.");
    b: String_Builder;
    append(*b, "{\"data\":");
    txn_json(*b, t);
    append(*b, "}");
    return ok_result(200, builder_to_string(*b));
}

set_category :: (id: string, body: string) -> Http_Result {
    t := find_txn(id);
    if !t return error_result(404, "Not Found", "The transaction does not exist.");
    doc, ok := json_parse(body,, temp);
    if !ok return error_result(400, "Invalid Request", "The request body is not valid JSON.");
    if !t.categorizable return error_result(403, "Forbidden", "This transaction cannot be categorized.");
    data := json_get(*doc, "data");
    if json_is_null(data) {
        t.category = "";
        return ok_result(204, "");
    }
    category := json_string(json_get(data, "id"));
    for CATEGORIES {
        if it.id != category continue;
        if !it.parent.count return error_result(422, "Invalid Category", "Parent categories cannot be assigned to transactions.");
        t.category = it.id;
        return ok_result(204, "");
    }
    return error_result(422, "Invalid Category", "The category does not exist.");
}

change_tags :: (id: string, body: string, add: bool) -> Http_Result {
    t := find_txn(id);
    if !t return error_result(404, "Not Found", "The transaction does not exist.");
    doc, ok := json_parse(body,, temp);
    if !ok return error_result(400, "Invalid Request", "The request body is not valid JSON.");
    for json_array(json_get(*doc, "data")) {
        label := json_string(json_get(*it, "id"));
        if !label.count continue;
        index := -1;
        for tag: t.tags if tag == label index = it_index;
        if add && index < 0 {
            if t.tags.count >= 6 return error_result(422, "Too Many Tags", "A transaction can have at most 6 tags.");
            array_add(*t.tags, copy_string(label));
        } else if !add && index >= 0 {
            array_ordered_remove_by_index(*t.tags, index);
        }
    }
    return ok_result(204, "");
}

webhook_json :: (b: *String_Builder, w: *Demo_Webhook, secret := "") {
    print_to_builder(b, "{\"type\":\"webhooks\",\"id\":\"%\",\"attributes\":{\"url\":\"%\",\"description\":%,", w.id, json_escape(w.url), str_or_null(w.description));
    if secret.count print_to_builder(b, "\"secretKey\":\"%\",", secret);
    print_to_builder(b, "\"createdAt\":\"%\"},\"relationships\":{\"logs\":{}}}", time_json(w.created));
}

list_webhooks :: () -> Http_Result {
    b: String_Builder;
    append(*b, "{\"data\":[");
    for * demo.webhooks {
        if it_index append(*b, ",");
        webhook_json(*b, it);
    }
    append(*b, "],\"links\":{\"prev\":null,\"next\":null}}");
    return ok_result(200, builder_to_string(*b));
}

create_webhook :: (body: string) -> Http_Result {
    doc, ok := json_parse(body,, temp);
    if !ok return error_result(400, "Invalid Request", "The request body is not valid JSON.");
    url := json_string(json_at(*doc, "data", "attributes", "url"));
    description := json_string(json_at(*doc, "data", "attributes", "description"));
    if !begins_with(url, "http://") && !begins_with(url, "https://") return error_result(422, "Invalid Attribute", "url must be an absolute http or https URL.");
    if url.count > 300 return error_result(422, "Invalid Attribute", "url must be at most 300 characters.");
    if description.count > 64 return error_result(422, "Invalid Attribute", "description must be at most 64 characters.");
    if demo.webhooks.count >= 10 return error_result(400, "Webhook Limit Reached", "There is a limit of 10 webhooks. Delete one before creating another.");
    w := array_add(*demo.webhooks);
    w.id = demo_uuid(*demo.rng);
    w.url = copy_string(url);
    w.description = copy_string(description);
    w.created = platform_local_time().utc_seconds;
    w.healthy = true;
    secret := tprint("%1%2", demo_uuid(*demo.rng), demo_uuid(*demo.rng));
    secret = replace(secret, "-", "",, temp);
    b: String_Builder;
    append(*b, "{\"data\":");
    webhook_json(*b, w, secret);
    append(*b, "}");
    return ok_result(201, builder_to_string(*b));
}

delete_webhook :: (id: string) -> Http_Result {
    for demo.webhooks {
        if it.id != id continue;
        array_ordered_remove_by_index(*demo.webhooks, it_index);
        return ok_result(204, "");
    }
    return error_result(404, "Not Found", "The webhook does not exist.");
}

ping_webhook :: (id: string) -> Http_Result {
    w: *Demo_Webhook;
    for * demo.webhooks if it.id == id w = it;
    if !w return error_result(404, "Not Found", "The webhook does not exist.");
    now := platform_local_time().utc_seconds;
    log: Demo_Log;
    log.id = demo_uuid(*demo.rng);
    log.webhook = w.id;
    log.event_id = demo_uuid(*demo.rng);
    log.event_type = "PING";
    log.created = now;
    log.status_code = cast(s32) ifx w.healthy || rng_chance(*demo.rng, 0.6) then 200 else 502;
    array_insert_at(*demo.logs, log, 0);
    body := sprint("{\"data\":{\"type\":\"webhook-events\",\"id\":\"%\",\"attributes\":{\"eventType\":\"PING\",\"createdAt\":\"%\"},\"relationships\":{\"webhook\":{\"data\":{\"type\":\"webhooks\",\"id\":\"%\"}}}}}", log.event_id, time_json(now), w.id);
    return ok_result(201, body);
}

list_webhook_logs :: (id: string, params: [] Param, path: string) -> Http_Result {
    known := false;
    for demo.webhooks if it.id == id known = true;
    if !known return error_result(404, "Not Found", "The webhook does not exist.");
    offset, _ := string_to_int(param(params, "page[after]"));
    size := page_size(params);
    b: String_Builder;
    append(*b, "{\"data\":[");
    matched := 0;
    written := 0;
    more := false;
    for * l: demo.logs {
        if l.webhook != id continue;
        matched += 1;
        if matched <= offset continue;
        if written == size { more = true; break; }
        if written append(*b, ",");
        written += 1;
        event := tprint("{\"data\":{\"type\":\"webhook-events\",\"id\":\"%\",\"attributes\":{\"eventType\":\"%\",\"createdAt\":\"%\"},\"relationships\":{\"webhook\":{\"data\":{\"type\":\"webhooks\",\"id\":\"%\"}}%}}}",
            l.event_id, l.event_type, time_json(l.created), l.webhook,
            ifx l.transaction.count then tprint(",\"transaction\":{\"data\":{\"type\":\"transactions\",\"id\":\"%\"}}", l.transaction) else "");
        print_to_builder(*b, "{\"type\":\"webhook-delivery-logs\",\"id\":\"%\",\"attributes\":{\"request\":{\"body\":\"%\"},", l.id, json_escape(event));
        if l.status_code {
            response := ifx l.status_code == 200 then "{\"ok\":true}" else "<html><body><h1>502 Bad Gateway</h1></body></html>";
            print_to_builder(*b, "\"response\":{\"statusCode\":%,\"body\":\"%\"},", l.status_code, json_escape(response));
            print_to_builder(*b, "\"deliveryStatus\":\"%\",", ifx l.status_code == 200 then "DELIVERED" else "BAD_RESPONSE_CODE");
        } else {
            append(*b, "\"response\":null,\"deliveryStatus\":\"UNDELIVERABLE\",");
        }
        print_to_builder(*b, "\"createdAt\":\"%\"},\"relationships\":{\"webhookEvent\":{\"data\":{\"type\":\"webhook-events\",\"id\":\"%\"}}}}", time_json(l.created), l.event_id);
    }
    append(*b, "]");
    page_links(*b, path, params, offset + written, more);
    append(*b, "}");
    return ok_result(200, builder_to_string(*b));
}

get_attachment :: (id: string) -> Http_Result {
    for t: demo.txns {
        if t.attachment != id continue;
        expires := platform_local_time().utc_seconds + 3600;
        body := sprint("{\"data\":{\"type\":\"attachments\",\"id\":\"%\",\"attributes\":{\"createdAt\":\"%\",\"fileURL\":null,\"fileURLExpiresAt\":\"%\",\"fileExtension\":\"jpg\",\"fileContentType\":\"image/jpeg\"},\"relationships\":{\"transaction\":{\"data\":{\"type\":\"transactions\",\"id\":\"%\"}}}}}",
            id, time_json(t.created), time_json(expires), t.id);
        return ok_result(200, body);
    }
    return error_result(404, "Not Found", "The attachment does not exist.");
}
