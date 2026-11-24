#pragma once
#include "TerminalRow.hpp"
#include <array>
#include <cstdio>
#include <memory>

namespace yaa {
// Append-only pages with a sequential on-disk index. Only one decoded page and
// the uncommitted tail are needed regardless of how long a session runs.
class HistoryArchive {
public:
    bool append(const Row &row);
    const Row &rowAt(int64_t index) const;
    int64_t size() const { return pageCount * rowsPerPage + pendingCount; }
    void dropReadCache();
    bool failed() const { return ioFailed; }
private:
    static constexpr int rowsPerPage = 32;
    struct Location { uint64_t offset; uint32_t bytes, plainBytes; };
    using File = std::unique_ptr<FILE, decltype(&fclose)>;
    File data{nullptr,fclose}, index{nullptr,fclose};
    int64_t pageCount = 0;
    uint64_t end = 0;
    int pendingCount = 0;
    mutable bool ioFailed = false;
    mutable int64_t flushed = 0, cachedPage = -1, cachedRow = -1;
    std::array<uint32_t,rowsPerPage> pendingOffsets{};
    mutable std::array<uint32_t,rowsPerPage> offsets{};
    std::vector<uint8_t> pending;
    mutable std::vector<uint8_t> decoded;
    mutable Row result;
    bool commit();
    bool load(int64_t page) const;
};
}
