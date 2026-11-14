describe("Maca plugin", function()
    local SyncFolder, Notebook, Stats, Library

    setup(function()
        require("commonrequire")
        package.path = "plugins/maca.koplugin/?.lua;plugins/coverbrowser.koplugin/?.lua;" .. package.path
        SyncFolder = require("maca/syncfolder")
        Notebook = require("maca/notebook")
        Stats = require("maca/stats")
        Library = require("maca/library")
    end)

    describe("highlight merge", function()
        local function hl(datetime, pos, text, updated)
            return { datetime = datetime, pos0 = pos, page = pos, drawer = "lighten", text = text, datetime_updated = updated }
        end

        it("adds highlights that only the other device has", function()
            local ours = { hl("2026-01-01 10:00:00", "/a", "one") }
            local theirs = { hl("2026-01-01 10:00:00", "/a", "one"), hl("2026-01-02 09:00:00", "/b", "two") }
            local merged, gained = SyncFolder.merge(ours, theirs)
            assert.is_equal(2, #merged)
            assert.is_equal(1, gained)
        end)

        it("keeps our copy unless theirs was edited later", function()
            local ours = { hl("2026-01-01 10:00:00", "/a", "ours", "2026-01-03 00:00:00") }
            local older = { hl("2026-01-01 10:00:00", "/a", "theirs", "2026-01-02 00:00:00") }
            local newer = { hl("2026-01-01 10:00:00", "/a", "theirs", "2026-01-04 00:00:00") }
            local merged, gained = SyncFolder.merge(ours, older)
            assert.is_equal("ours", merged[1].text)
            assert.is_equal(0, gained)
            merged, gained = SyncFolder.merge(ours, newer)
            assert.is_equal("theirs", merged[1].text)
            assert.is_equal(1, gained)
        end)

        it("copes with empty sides", function()
            local merged, gained = SyncFolder.merge(nil, nil)
            assert.is_equal(0, #merged)
            assert.is_equal(0, gained)
            merged, gained = SyncFolder.merge({}, { hl("2026-01-01 10:00:00", "/a", "x") })
            assert.is_equal(1, #merged)
            assert.is_equal(1, gained)
        end)
    end)

    describe("notes export", function()
        it("writes quotes, notes and chapter headings as Markdown", function()
            local text = Notebook.markdown({ title = "A Book", authors = "Ann\nBob" }, {
                { drawer = "lighten", text = "first line\nsecond line", chapter = "One", pageno = 3 },
                { drawer = "lighten", text = "another", note = "my thought", chapter = "One", pageno = 4 },
                { drawer = "lighten", text = "later", chapter = "Two", pageno = 9 },
            })
            assert.truthy(text:find("# A Book", 1, true))
            assert.truthy(text:find("*Ann, Bob*", 1, true))
            assert.truthy(text:find("> first line\n> second line", 1, true))
            assert.truthy(text:find("my thought", 1, true))
            local _, headings = text:gsub("\n## ", "")
            assert.is_equal(2, headings)
        end)
    end)

    describe("library queries", function()
        local saved

        setup(function()
            saved = Library.books
            Library.books = {
                { file = "/l/a.epub", title = "Zebra", author = "Ann", authors = "Ann", status = "reading", percent = 0.5,
                  last_read = 300, added = 10, series = "Saga", series_index = 2 },
                { file = "/l/b.epub", title = "apple", author = "Bob", authors = "Bob\nAnn", status = "new", percent = 0,
                  added = 30, series = "Saga", series_index = 1, keywords = "fruit" },
                { file = "/l/sub/c.epub", title = "Mango", author = "Cy", authors = "Cy", status = "complete", percent = 1,
                  last_read = 100, added = 20, series = "Saga", series_index = 3 },
            }
        end)

        teardown(function()
            Library.books = saved
        end)

        it("filters by status", function()
            assert.is_equal(1, #Library:query{ status = "reading" })
            assert.is_equal(3, #Library:query{ status = "all" })
        end)

        it("searches title, author and tags without regard to case", function()
            assert.is_equal("apple", Library:query{ search = "APP" }[1].title)
            assert.is_equal(2, #Library:query{ search = "ann" })
            assert.is_equal(1, #Library:query{ search = "fruit" })
        end)

        it("sorts by title ignoring case, and by most recently read", function()
            local by_title = Library:query{ sort = "title" }
            assert.is_equal("apple", by_title[1].title)
            assert.is_equal("Zebra", by_title[3].title)
            assert.is_equal("Zebra", Library:query{ sort = "recent" }[1].title)
        end)

        it("groups by author, listing a co-written book under each author", function()
            local groups = Library:groups("author", {})
            assert.is_equal(3, #groups)
            assert.is_equal("Ann", groups[1].name)
            assert.is_equal(2, #groups[1].books)
        end)

        it("counts books per status", function()
            local counts = Library:counts()
            assert.is_equal(3, counts.all)
            assert.is_equal(1, counts.complete)
        end)

        it("finds the current book and the next one in a series", function()
            assert.is_equal("Zebra", Library:current().title)
            assert.is_equal("Mango", Library:nextInSeries(Library.books[1]).title)
            assert.is_nil(Library:nextInSeries(Library.books[3]))
        end)
    end)

    describe("statistics helpers", function()
        it("finds local midnight", function()
            local noon = os.time{ year = 2026, month = 3, day = 14, hour = 12 }
            local start = Stats.dayStart(noon)
            assert.is_equal("2026-03-14 00:00:00", os.date("%Y-%m-%d %H:%M:%S", start))
            assert.is_equal("2026-03-14", Stats.dayKey(noon))
        end)
    end)
end)
