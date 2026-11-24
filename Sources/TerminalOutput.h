#import <AppKit/AppKit.h>
#include "TerminalSearch.hpp"
#include <optional>

// Every non-file table shares the existing bounded reference pool.
enum class ListingFormat : uint8_t {
    Files, Containers, Images, Networks, Volumes, Disk, Processes, UserProcesses, FullProcesses,
    Jobs, Packages, Remotes, Worktrees, Pods, Services, Deployments, Namespaces, ImageUsage, Count
};
struct ListingSpec {
    const char *key;
    NSArray<NSString *> *labels;
    NSString *headerPattern, *rowPattern;
    uint8_t capture[8];
    int8_t widths[8]; // Minimum widths in glyphs. Negative widths align numbers to the right.
};
const ListingSpec &SpecForListing(ListingFormat format);
std::optional<ListingFormat> FormatForOutput(std::string_view key);
enum OutputKind : unsigned { DirectoryContext, FileListing, CommandListing, ExplicitLink };
@interface OutputReference : NSObject
@property uint32_t tag, parent;
@property ListingFormat format;
@property (copy) NSString *directory;
@property NSURL *url;
@property BOOL raw;
@end

@interface OutputReferences : NSObject
- (uint32_t)context:(OutputKind)kind directory:(NSString *)directory;
- (uint32_t)listing:(ListingFormat)format directory:(NSString *)directory;
- (uint32_t)link:(NSURL *)url parent:(uint32_t)parent;
- (OutputReference *)record:(uint32_t)tag;
- (void)discardTables:(BOOL)tables web:(BOOL)web files:(BOOL)files;
@end

struct OutputLine {
    NSString *text = nil;
    NSUInteger index = 0; // UTF-16 index of the clicked cell.
    int64_t first = 0, last = 0;
};
// Read one soft-wrapped line. Archive row references are transient.
OutputLine ReadOutputLine(const yaa::Screen &screen, yaa::TextPoint point);
bool IsListingHeader(ListingFormat format, NSString *line);
NSArray<NSString *> *ListingFields(ListingFormat format, NSString *line);
struct ParsedListing {
    ListingFormat format;
    bool header;
    NSArray<NSString *> *fields;
};
ParsedListing ParseListing(ListingFormat format, NSString *text, bool includeData);
NSURL *TerminalURI(NSString *text, BOOL web, BOOL files);
NSURL *LinkInOutput(NSString *line, NSUInteger index, NSString *directory, BOOL web, BOOL files);
NSURL *ExistingListingFile(NSString *name, NSString *directory);
