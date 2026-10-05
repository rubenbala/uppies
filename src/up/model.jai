// The data model: what the Up API describes, parsed out of JSON:API
// resources into compact structs that index each other by position.
//
// Money is integer cents. Every Transaction owns its strings in a single
// allocation (`storage`), so dropping one is one free.

Account_Type :: enum u8 { TRANSACTIONAL; SAVER; HOME_LOAN; OTHER; }
Ownership    :: enum u8 { INDIVIDUAL; JOINT; OTHER; }

Account :: struct {
    id:        string;
    name:      string;
    currency:  string;
    type:      Account_Type;
    ownership: Ownership;
    balance:   s64;
    created:   Timestamp;
}

Category :: struct {
    id:     string;   // "restaurants-and-cafes"
    name:   string;   // "Restaurants & Cafes"
    parent: s32 = -1; // Index of the parent; -1 for a parent category.
    parent_id: string;
}

Tag :: struct {
    label: string;    // A tag's label is also its id.
}

Txn_Status :: enum u8 { SETTLED; HELD; }

Card_Method :: enum u8 {
    NONE; BAR_CODE; OCR; CARD_PIN; CARD_DETAILS; CARD_ON_FILE; ECOMMERCE; MAGNETIC_STRIPE; CONTACTLESS;
}

CARD_METHOD_NAMES :: string.["", "Barcode", "OCR", "Card + PIN", "Card details", "Card on file", "Online", "Magnetic stripe", "Contactless"];

MAX_TAGS :: 6;   // Up allows six tags per transaction.

Transaction :: struct {
    id:               string;
    description:      string;
    raw_text:         string;
    message:          string;
    note:             string;
    transaction_type: string;
    performer:        string;
    card_suffix:      string;
    foreign_currency: string;
    foreign_value:    string;
    cashback_description: string;
    attachment_id:    string;

    amount:         s64;
    hold_amount:    s64;
    round_up:       s64;   // Negative: what left the account on top of `amount`.
    round_up_boost: s64;
    cashback:       s64;

    created: Timestamp;
    settled: Timestamp;
    day:     s32;          // Local calendar day of `created`.
    month:   s32;          // Month key of `day`.

    account:          s32 = -1;
    transfer_account: s32 = -1;
    category:         s16 = -1;
    parent_category:  s16 = -1;
    tags: [MAX_TAGS] s16;
    tag_count: s32;

    status:        Txn_Status;
    card_method:   Card_Method;
    categorizable: bool;
    has_hold:      bool;
    has_settled:   bool;
    has_foreign:   bool;
    has_round_up:  bool;
    has_cashback:  bool;

    arrived_at: float64;   // UI clock when first seen: fresh rows get a brief highlight.
    storage: *u8;
}

is_transfer :: inline (t: *Transaction) -> bool { return t.transfer_account >= 0; }

// What the transaction did to its account's balance: the amount plus any
// Round Up swept to a saver alongside it.
balance_effect :: inline (t: *Transaction) -> s64 { return t.amount + t.round_up; }

Webhook :: struct {
    id:          string;
    url:         string;
    description: string;
    created:     Timestamp;
}

Delivery_Status :: enum u8 { DELIVERED; UNDELIVERABLE; BAD_RESPONSE_CODE; OTHER; }

Webhook_Log :: struct {
    id:            string;
    event_type:    string;    // From the request body: TRANSACTION_CREATED, PING...
    transaction_id: string;
    request_body:  string;
    response_body: string;
    status_code:   s32;       // 0 when there was no response.
    has_response:  bool;
    delivery:      Delivery_Status;
    created:       Timestamp;
}

//
// Parsing JSON:API resources. All strings are copied to the heap (or, for
// transactions, into the transaction's storage).
//

parse_account :: (res: *JSON) -> Account {
    a: Account;
    a.id   = copy_string(json_string(json_get(res, "id")));
    attrs := json_get(res, "attributes");
    a.name = copy_string(json_string(json_get(attrs, "displayName")));
    type := json_string(json_get(attrs, "accountType"));
    a.type = ifx type == "TRANSACTIONAL" then .TRANSACTIONAL else ifx type == "SAVER" then .SAVER else ifx type == "HOME_LOAN" then .HOME_LOAN else .OTHER;
    own := json_string(json_get(attrs, "ownershipType"));
    a.ownership = ifx own == "INDIVIDUAL" then .INDIVIDUAL else ifx own == "JOINT" then .JOINT else .OTHER;
    a.balance  = json_int(json_at(attrs, "balance", "valueInBaseUnits"));
    a.currency = copy_string(json_string(json_at(attrs, "balance", "currencyCode")));
    a.created  = parse_rfc3339(json_string(json_get(attrs, "createdAt")));
    return a;
}

free_account :: (a: *Account) {
    free(a.id); free(a.name); free(a.currency);
}

parse_category :: (res: *JSON) -> Category {
    c: Category;
    c.id   = copy_string(json_string(json_get(res, "id")));
    c.name = copy_string(json_string(json_at(res, "attributes", "name")));
    c.parent_id = copy_string(json_string(json_at(res, "relationships", "parent", "data", "id")));
    return c;
}

free_category :: (c: *Category) {
    free(c.id); free(c.name); free(c.parent_id);
}

// Relationship ids are resolved against the store's accounts, categories and
// tags; unknown tags are registered.
parse_transaction :: (res: *JSON, store: *Store) -> Transaction {
    t: Transaction;
    attrs := json_get(res, "attributes");
    rels  := json_get(res, "relationships");

    t.id               = json_string(json_get(res, "id"));
    t.description      = json_string(json_get(attrs, "description"));
    t.raw_text         = json_string(json_get(attrs, "rawText"));
    t.message          = json_string(json_get(attrs, "message"));
    t.note             = json_string(json_at(attrs, "note", "text"));
    t.transaction_type = json_string(json_get(attrs, "transactionType"));
    t.performer        = json_string(json_at(attrs, "performingCustomer", "displayName"));

    status := json_string(json_get(attrs, "status"));
    t.status = ifx status == "HELD" then .HELD else .SETTLED;
    t.categorizable = json_bool(json_get(attrs, "isCategorizable"));

    t.amount = json_int(json_at(attrs, "amount", "valueInBaseUnits"));

    hold := json_get(attrs, "holdInfo");
    if !json_is_null(hold) {
        t.has_hold = true;
        t.hold_amount = json_int(json_at(hold, "amount", "valueInBaseUnits"));
    }
    round := json_get(attrs, "roundUp");
    if !json_is_null(round) {
        t.has_round_up = true;
        t.round_up = json_int(json_at(round, "amount", "valueInBaseUnits"));
        boost := json_get(round, "boostPortion");
        if !json_is_null(boost) t.round_up_boost = json_int(json_get(boost, "valueInBaseUnits"));
    }
    cashback := json_get(attrs, "cashback");
    if !json_is_null(cashback) {
        t.has_cashback = true;
        t.cashback = json_int(json_at(cashback, "amount", "valueInBaseUnits"));
        t.cashback_description = json_string(json_get(cashback, "description"));
    }
    foreign := json_get(attrs, "foreignAmount");
    if !json_is_null(foreign) {
        t.has_foreign = true;
        t.foreign_currency = json_string(json_get(foreign, "currencyCode"));
        t.foreign_value    = json_string(json_get(foreign, "value"));
    }
    card := json_get(attrs, "cardPurchaseMethod");
    if !json_is_null(card) {
        method := json_string(json_get(card, "method"));
        for CARD_METHOD_IDS if it == method { t.card_method = cast(Card_Method) it_index; break; }
        t.card_suffix = json_string(json_get(card, "cardNumberSuffix"));
    }

    t.created = parse_rfc3339(json_string(json_get(attrs, "createdAt")));
    settled_text := json_string(json_get(attrs, "settledAt"));
    if settled_text.count t.settled, t.has_settled = parse_rfc3339(settled_text);
    t.day   = cast(s32) ts_day(t.created);
    t.month = month_key_from_day(t.day);

    t.account          = store_find_account(store, json_string(json_at(rels, "account", "data", "id")));
    t.transfer_account = store_find_account(store, json_string(json_at(rels, "transferAccount", "data", "id")));
    t.category         = cast(s16) store_find_category(store, json_string(json_at(rels, "category", "data", "id")));
    t.parent_category  = cast(s16) store_find_category(store, json_string(json_at(rels, "parentCategory", "data", "id")));
    if t.category >= 0 && t.parent_category < 0 t.parent_category = cast(s16) store.categories[t.category].parent;

    for json_array(json_at(rels, "tags", "data")) {
        if t.tag_count >= MAX_TAGS break;
        label := json_string(json_get(*it, "id"));
        if !label.count continue;
        t.tags[t.tag_count] = cast(s16) store_intern_tag(store, label);
        t.tag_count += 1;
    }
    t.attachment_id = json_string(json_at(rels, "attachment", "data", "id"));

    pack_transaction_strings(*t);
    return t;
}

// Moves every string the transaction refers to into one allocation it owns.
pack_transaction_strings :: (t: *Transaction) {
    fields := (*string).[
        *t.id, *t.description, *t.raw_text, *t.message, *t.note, *t.transaction_type, *t.performer,
        *t.card_suffix, *t.foreign_currency, *t.foreign_value, *t.cashback_description, *t.attachment_id,
    ];
    total := 0;
    for fields total += it.count;
    old_storage := t.storage;
    t.storage = alloc(max(total, 1));
    at := t.storage;
    for fields {
        if it.count memcpy(at, it.data, it.count);
        it.data = at;
        at += it.count;
    }
    if old_storage free(old_storage);
}

free_transaction :: (t: *Transaction) {
    if t.storage free(t.storage);
    t.storage = null;
}

parse_webhook :: (res: *JSON) -> Webhook, secret: string {
    w: Webhook;
    attrs := json_get(res, "attributes");
    w.id          = copy_string(json_string(json_get(res, "id")));
    w.url         = copy_string(json_string(json_get(attrs, "url")));
    w.description = copy_string(json_string(json_get(attrs, "description")));
    w.created     = parse_rfc3339(json_string(json_get(attrs, "createdAt")));
    secret        := copy_string(json_string(json_get(attrs, "secretKey")));
    return w, secret;
}

free_webhook :: (w: *Webhook) {
    free(w.id); free(w.url); free(w.description);
}

parse_webhook_log :: (res: *JSON) -> Webhook_Log {
    l: Webhook_Log;
    attrs := json_get(res, "attributes");
    l.id = copy_string(json_string(json_get(res, "id")));
    l.request_body = copy_string(json_string(json_at(attrs, "request", "body")));
    response := json_get(attrs, "response");
    if !json_is_null(response) {
        l.has_response  = true;
        l.status_code   = cast(s32) json_int(json_get(response, "statusCode"));
        l.response_body = copy_string(json_string(json_get(response, "body")));
    }
    status := json_string(json_get(attrs, "deliveryStatus"));
    l.delivery = ifx status == "DELIVERED" then .DELIVERED else ifx status == "UNDELIVERABLE" then .UNDELIVERABLE else ifx status == "BAD_RESPONSE_CODE" then .BAD_RESPONSE_CODE else .OTHER;
    l.created = parse_rfc3339(json_string(json_get(attrs, "createdAt")));

    // The event type and transaction live in the delivered request body.
    event, ok := json_parse(l.request_body,, temp);
    if ok {
        l.event_type     = copy_string(json_string(json_at(*event, "data", "attributes", "eventType")));
        l.transaction_id = copy_string(json_string(json_at(*event, "data", "relationships", "transaction", "data", "id")));
    }
    return l;
}

free_webhook_log :: (l: *Webhook_Log) {
    free(l.id); free(l.event_type); free(l.transaction_id); free(l.request_body); free(l.response_body);
}

// The API's error document, as one readable line: "Not Authorized: The request was not authenticated...".
parse_api_error :: (body: string) -> string {
    doc, ok := json_parse(body,, temp);
    if !ok return "";
    errors := json_array(json_get(*doc, "errors"));
    if !errors.count return "";
    title  := json_string(json_get(*errors[0], "title"));
    detail := json_string(json_get(*errors[0], "detail"));
    if title.count && detail.count return tprint("%: %", title, detail);
    return ifx detail.count then detail else title;
}

#scope_file

CARD_METHOD_IDS :: string.["", "BAR_CODE", "OCR", "CARD_PIN", "CARD_DETAILS", "CARD_ON_FILE", "ECOMMERCE", "MAGNETIC_STRIPE", "CONTACTLESS"];
