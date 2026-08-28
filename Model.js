.pragma library

// Formatting shared by the bar widget and the panel. Kept out of the QML so
// both read the same rules and neither grows its own slightly different copy.

var DASH = "—"

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function pad(value) { return value < 10 ? "0" + value : String(value) }

// Relative for anything recent enough to remember, absolute after that. The
// point is to answer "is this the note I was just in?" at a glance.
function whenText(epoch) {
  if (epoch === null || epoch === undefined || isNaN(Number(epoch))) return ""
  var when = new Date(Number(epoch) * 1000)
  var now = new Date()
  var seconds = Math.floor((now.getTime() - when.getTime()) / 1000)
  if (seconds < 60) return "just now"
  if (seconds < 3600) return Math.floor(seconds / 60) + "m ago"
  if (when.getFullYear() === now.getFullYear()
      && when.getMonth() === now.getMonth()
      && when.getDate() === now.getDate()) {
    return "today " + pad(when.getHours()) + ":" + pad(when.getMinutes())
  }
  if (seconds < 7 * 86400) return Math.floor(seconds / 86400) + "d ago"
  var stamp = pad(when.getDate()) + " " + MONTHS[when.getMonth()]
  if (when.getFullYear() !== now.getFullYear()) stamp += " " + when.getFullYear()
  return stamp
}

// The folder a note sits in, which is most of what tells two notes with the
// same title apart. The filename itself is already the row's heading.
function folderOf(relPath) {
  var text = String(relPath || "")
  var cut = text.lastIndexOf("/")
  return cut < 0 ? "" : text.slice(0, cut)
}

function fmtCount(count, singular, plural) {
  return count + " " + (count === 1 ? singular : plural)
}

// Frontmatter is metadata, not the note. Showing it in a preview wastes the
// first screenful on YAML nobody wants to read.
function stripFrontmatter(text) {
  var body = String(text || "")
  if (body.indexOf("---\n") !== 0) return body
  var end = body.indexOf("\n---", 3)
  if (end < 0) return body
  var after = body.indexOf("\n", end + 1)
  return after < 0 ? "" : body.slice(after + 1).replace(/^\n+/, "")
}

// The preview pane already shows the note's title in its own header, so a
// leading H1 saying the same thing is the heading printed twice.
function previewBody(text, title) {
  var body = stripFrontmatter(text)
  var heading = String(title || "").trim()
  if (heading === "") return body
  var firstBreak = body.indexOf("\n")
  var firstLine = (firstBreak < 0 ? body : body.slice(0, firstBreak)).trim()
  if (firstLine.replace(/^#{1,6}\s*/, "").trim() !== heading) return body
  return firstBreak < 0 ? "" : body.slice(firstBreak + 1).replace(/^\n+/, "")
}
