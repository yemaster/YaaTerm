#include "History.hpp"
#include <compression.h>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>

namespace yaa {
namespace {
struct Header { uint16_t columns, used, wrapAt; };
FILE *temporaryFile() {
    FILE *file = std::tmpfile();  // Unlinked, private to this session.
    if (file && fcntl(fileno(file),F_SETFD,FD_CLOEXEC) < 0) { fclose(file); return nullptr; }
    return file;
}
bool readAt(FILE *f, void *destination, size_t count, uint64_t offset) {
    auto *out = static_cast<uint8_t *>(destination);
    while (count) {
        ssize_t n = pread(fileno(f),out,count,offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        count -= n; offset += n; out += n;
    }
    return true;
}
}
void HistoryArchive::dropReadCache() {
    cachedPage = cachedRow = -1;
    std::vector<uint8_t>().swap(decoded);
    Row{}.swap(result);
}
bool HistoryArchive::append(const Row &row) {
    if (ioFailed) return false;
    if (pendingCount == rowsPerPage && !commit()) { ioFailed = true; return false; }
    Header header{(uint16_t)row.size(),(uint16_t)row.used(),(uint16_t)row.wrapAt};
    size_t start = pending.size(), cells = header.used*sizeof(Cell);
    pendingOffsets[pendingCount++] = (uint32_t)start;
    pending.resize(start + sizeof(header) + cells);
    memcpy(pending.data()+start,&header,sizeof(header));
    if (cells) memcpy(pending.data()+start+sizeof(header),row.data(),cells);
    return true;
}
bool HistoryArchive::commit() {
    if (!data) { data.reset(temporaryFile()); index.reset(temporaryFile()); }
    if (!data || !index) return false;
    // The main thread serializes writes. Reuse compression workspace between panes.
    static thread_local std::vector<uint8_t> compressed, scratch(compression_encode_scratch_buffer_size(COMPRESSION_LZ4));
    compressed.resize(pending.size());
    size_t bytes = compression_encode_buffer(compressed.data(),compressed.size(),pending.data(),pending.size(),scratch.data(),COMPRESSION_LZ4);
    bool smaller = bytes && bytes < pending.size();
    auto &payload = smaller ? compressed : pending;
    Location location{end,(uint32_t)(smaller ? bytes : pending.size()),(uint32_t)pending.size()};
    if (fwrite(payload.data(),1,location.bytes,data.get()) != location.bytes ||
        fwrite(&location,sizeof(location),1,index.get()) != 1) return false;
    end += location.bytes; ++pageCount;
    pendingCount = 0; pending.clear();
    return true;
}
bool HistoryArchive::load(int64_t page) const {
    if (page == cachedPage) return true;
    if (page >= flushed) {
        if (fflush(data.get()) || fflush(index.get())) return false;
        flushed = pageCount;
    }
    Location loc{};
    if (!readAt(index.get(),&loc,sizeof(loc),page*sizeof(loc)) || !loc.bytes ||
        loc.bytes > loc.plainBytes || loc.plainBytes > rowsPerPage*(sizeof(Header)+1000*sizeof(Cell))) return false;
    decoded.resize(loc.plainBytes);
    cachedPage = cachedRow = -1;
    if (loc.bytes == loc.plainBytes) {
        if (!readAt(data.get(),decoded.data(),loc.bytes,loc.offset)) return false;
    } else {
        static thread_local std::vector<uint8_t> compressed;
        compressed.resize(loc.bytes);
        if (!readAt(data.get(),compressed.data(),loc.bytes,loc.offset) ||
            compression_decode_buffer(decoded.data(),decoded.size(),compressed.data(),compressed.size(),nullptr,COMPRESSION_LZ4) != decoded.size()) return false;
    }
    size_t cursor = 0;
    for (auto &offset : offsets) {
        Header h{};
        if (cursor + sizeof(h) > decoded.size()) return false;
        memcpy(&h,decoded.data()+cursor,sizeof(h));
        if (h.used > h.columns || h.columns > 1000 || h.wrapAt > h.columns) return false;
        offset = (uint32_t)cursor; cursor += sizeof(h)+h.used*sizeof(Cell);
    }
    if (cursor != decoded.size()) return false;
    cachedPage = page;
    return true;
}
const Row &HistoryArchive::rowAt(int64_t index) const {
    if (cachedRow == index) {
        if (ioFailed && index+1 == size()) result.wrapAt = 0;
        return result;
    }
    int64_t page = index / rowsPerPage;
    int slot = index % rowsPerPage;
    const uint8_t *record;
    if (page == pageCount) record = pending.data()+pendingOffsets[slot];
    else {
        if (!load(page)) { ioFailed = true; cachedRow = -1; result.clear(); result.wrapAt = result.written = 0; return result; }
        record = decoded.data()+offsets[slot];
    }
    Header h; memcpy(&h,record,sizeof(h));
    result.assign(h.columns,Cell{}); result.wrapAt = h.wrapAt; result.written = h.used;
    memcpy(result.data(),record+sizeof(h),h.used*sizeof(Cell));
    if (ioFailed && index+1 == size()) result.wrapAt = 0;
    cachedRow = index;
    return result;
}
}
