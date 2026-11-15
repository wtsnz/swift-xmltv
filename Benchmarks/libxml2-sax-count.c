// The libxml2 baseline in Performance.md: SAX2 over a file, counting start tags and building
// nothing. It is the fastest any parser built on libxml2's SAX interface can be, on one thread.
//
//     cc -O2 Benchmarks/libxml2-sax-count.c $(xml2-config --cflags --libs) -o /tmp/sax-count
//     /tmp/sax-count feed.xml 7
//
// On macOS without xml2-config, use the SDK's copy:
//
//     cc -O2 Benchmarks/libxml2-sax-count.c -I"$(xcrun --show-sdk-path)/usr/include/libxml2" -lxml2 -o /tmp/sax-count
#include <libxml/parser.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>

static long count = 0;

static void startElement(void *context, const xmlChar *localName, const xmlChar *prefix, const xmlChar *uri,
                         int namespaceCount, const xmlChar **namespaces, int attributeCount, int defaultedCount,
                         const xmlChar **attributes) {
    count++;
}

static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file> [repetitions]\n", argv[0]);
        return 1;
    }
    int repetitions = argc > 2 ? atoi(argv[2]) : 7;
    if (repetitions < 1 || repetitions > 100) repetitions = 7;
    struct stat info;
    if (stat(argv[1], &info) != 0) {
        perror(argv[1]);
        return 1;
    }

    xmlSAXHandler handler = {0};
    handler.initialized = XML_SAX2_MAGIC;
    handler.startElementNs = startElement;
    double seconds[100];
    for (int i = 0; i < repetitions; i++) {
        count = 0;
        struct timespec start, end;
        clock_gettime(CLOCK_MONOTONIC, &start);
        if (xmlSAXUserParseFile(&handler, NULL, argv[1]) != 0) {
            fprintf(stderr, "libxml2 reported an error\n");
            return 1;
        }
        clock_gettime(CLOCK_MONOTONIC, &end);
        seconds[i] = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    }
    qsort(seconds, repetitions, sizeof seconds[0], compare);
    double median = seconds[repetitions / 2];
    printf("libxml2 SAX2 %s: %ld elements, median %.1f ms = %.2f GB/s\n",
           argv[1], count, median * 1000, info.st_size / median / 1e9);
    return 0;
}
