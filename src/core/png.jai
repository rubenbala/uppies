// Minimal PNG writer for screenshots: 8-bit RGB, zlib "stored" (uncompressed)
// deflate blocks. Bigger files than a real encoder, but no dependencies and
// nothing to get wrong.

write_png_rgb :: (path: string, width: s32, height: s32, rgb: *u8) -> bool {
    builder: String_Builder;
    builder.allocator = temp;

    append(*builder, "\x89PNG\r\n\x1a\n");

    ihdr: [13] u8;
    put_be32(ihdr.data, cast(u32) width);
    put_be32(ihdr.data + 4, cast(u32) height);
    ihdr[8]  = 8;   // Bit depth.
    ihdr[9]  = 2;   // Color type: RGB.
    ihdr[10] = 0;   // Compression.
    ihdr[11] = 0;   // Filter.
    ihdr[12] = 0;   // Interlace.
    png_chunk(*builder, "IHDR", ihdr);

    // Raw scanlines, each prefixed by filter type 0.
    row_bytes := width * 3 + 1;
    raw := NewArray(row_bytes * height, u8,, temp);
    for y: 0..height - 1 {
        raw[y * row_bytes] = 0;
        memcpy(raw.data + y * row_bytes + 1, rgb + y * width * 3, width * 3);
    }

    // zlib stream of stored blocks (at most 65535 bytes each).
    zlib: String_Builder;
    zlib.allocator = temp;
    append(*zlib, cast(u8) 0x78);
    append(*zlib, cast(u8) 0x01);
    offset := 0;
    while offset < raw.count || raw.count == 0 {
        n := min(raw.count - offset, 65535);
        final := offset + n >= raw.count;
        header: [5] u8;
        header[0] = ifx final then cast(u8) 1 else cast(u8) 0;
        header[1] = cast(u8) (n & 0xFF);
        header[2] = cast(u8) ((n >> 8) & 0xFF);
        header[3] = cast(u8) (~n & 0xFF);
        header[4] = cast(u8) ((~n >> 8) & 0xFF);
        append(*zlib, header.data, 5);
        append(*zlib, raw.data + offset, n);
        offset += n;
        if final break;
    }
    adler: [4] u8;
    put_be32(adler.data, adler32(raw));
    append(*zlib, adler.data, 4);
    zdata := builder_to_string(*zlib,, temp);
    png_chunk(*builder, "IDAT", cast([] u8) zdata);

    png_chunk(*builder, "IEND", .[]);
    return write_entire_file(path, *builder);
}

#scope_file

put_be32 :: (p: *u8, v: u32) {
    p[0] = cast(u8) ((v >> 24) & 0xFF);
    p[1] = cast(u8) ((v >> 16) & 0xFF);
    p[2] = cast(u8) ((v >> 8) & 0xFF);
    p[3] = cast(u8) (v & 0xFF);
}

png_chunk :: (builder: *String_Builder, type: string, data: [] u8) {
    length: [4] u8;
    put_be32(length.data, cast(u32) data.count);
    append(builder, length.data, 4);
    append(builder, type);
    append(builder, data.data, data.count);
    crc := crc32_update(0xFFFF_FFFF, cast([] u8) type);
    crc  = crc32_update(crc, data) ^ 0xFFFF_FFFF;
    tail: [4] u8;
    put_be32(tail.data, crc);
    append(builder, tail.data, 4);
}

crc_table: [256] u32;
crc_table_ready: bool;

crc32_update :: (crc_in: u32, data: [] u8) -> u32 {
    if !crc_table_ready {
        for n: 0..255 {
            c := cast(u32) n;
            for 0..7 c = ifx c & 1 then 0xEDB88320 ^ (c >> 1) else c >> 1;
            crc_table[n] = c;
        }
        crc_table_ready = true;
    }
    crc := crc_in;
    for data crc = crc_table[(crc ^ it) & 0xFF] ^ (crc >> 8);
    return crc;
}

adler32 :: (data: [] u8) -> u32 {
    a: u32 = 1;
    b: u32 = 0;
    for data {
        a = (a + it) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}
