aglio = require './main'
chokidar = require 'chokidar'
clc = require 'cli-color'
fs = require 'fs'
http = require 'http'
path = require 'path'
serveStatic = require 'serve-static'
parser = require('yargs')
    .usage('Usage: $0 [options] -i infile [-o outfile -s]')
    .example('$0 -i example.apib -o output.html', 'Render to HTML')
    .example('$0 -i example.apib -s', 'Start preview server')
    .example('$0 -t flatly -i example.apib -s', 'Custom template')
    .example('$0 --no-condense -i example.apib -s', 'Disable options')
    .options('i', alias: 'input', describe: 'Input file')
    .options('o', alias: 'output', describe: 'Output file')
    .options('t', alias: 'theme', describe: 'Theme name or layout file', default: 'default')
    .options('f', alias: 'filter', boolean: true, describe: 'Sanitize input from Windows', default: true)
    .options('c', alias: 'condense', boolean: true, describe: 'Condense navigation links', default: true)
    .options('w', alias: 'full-width', boolean: true, describe: 'Use full window width', default: false)
    .options('s', alias: 'server', describe: 'Start a local live preview server')
    .options('h', alias: 'host', describe: 'Address to bind local preview server to', default: '127.0.0.1')
    .options('p', alias: 'port', describe: 'Port for local preview server', default: 3000)
    .options('v', alias: 'version', describe: 'Display version number', default: false)
    .options('c', alias: 'compile', describe: 'Compile the markdown file')
    .epilog('See https://github.com/danielgtaylor/aglio#readme for more information')

# Console color settings for error/warnings
cErr = clc.white.bgRed
cWarn = clc.xterm(214).bgXterm(235)

# Get a line number from an error if possible
getLineNo = (input, err) ->
    if err.location and err.location.length
        input.substr(0, err.location[0].index).split('\n').length

# Output warning info
logWarnings = (warnings) ->
    for warning in warnings or []
        lineNo = getLineNo(warnings.input, warning) or 0
        console.error cWarn(">> Line #{lineNo}:") + " #{warning.message} (warning code #{warning.code})"

exports.run = (argv=parser.argv, done=->) ->
    _html = null
    getHtml = (cb) ->
        if _html
            cb and cb(null, _html)
        else
            fs.readFile argv.i, "utf-8", (err, blueprint) ->
                console.log "Rendering " + argv.i
                aglio.render blueprint, argv, (err, html, warnings) ->
                    logWarnings warnings
                    if err
                        console.error err
                        cb and cb(err)
                    else
                        _html = html
                        cb and cb(null, _html)

    if argv.version
        console.log("aglio #{require('../package.json').version}")
        return done()

    # The option used to be called `template`
    if argv.template then argv.theme = argv.template

    # Add theme options to the help output
    try
        theme = aglio.getTheme(argv.theme)
    catch err
        return done(err)

    config = theme.getConfig()
    for entry in config.options
        parser.options("theme-#{entry.name}", entry)

    if argv.s
        if not argv.i
            parser.showHelp()
            return done 'Invalid arguments'

        argv.locals =
            livePreview: true

        getHtml()
        server = http.createServer((req, res) ->
            if req.url isnt '/'
                serve = serveStatic(path.dirname(argv.i))
                return serve(req, res, () -> res.end())

            getHtml (err, html) ->
                res.writeHead 200,
                    "Content-Type": "text/html"

                res.end (if err then err.toString() else html)

        ).listen argv.p, argv.h, ->
            console.log "Server started on http://#{argv.h}:#{argv.p}/"

        sendHtml = (socket) ->
            getHtml (err, html) ->
                unless err
                    console.log "Refresh web page in browser"
                    re = /<body.*?>[^]*<\/body>/gi
                    html = html.match(re)[0]
                    socket.emit "refresh", html

        io = require("socket.io")(server)
        io.on "connection", (socket) ->
            console.log "Socket connected"
            socket.on 'request-refresh', ->
                sendHtml socket

        paths = aglio.collectPathsSync fs.readFileSync(argv.i, 'utf-8'), path.dirname(argv.i)

        watcher = chokidar.watch [argv.i].concat(paths)
        watcher.on "change", (path) ->
            console.log "Updated " + path
            _html = null
            sendHtml io

        done()
    else
        # Render or Compile API Blueprint, requires input/output files
        if not argv.i or not argv.o
            parser.showHelp()
            return done 'Invalid arguments'

        if argv.c or argv.o.match /\.apib$/ or argv.o.match /\.md$/
            aglio.compileFile argv.i, argv.o, (err) ->
                if (err)
                    console.error cErr('>>') + " #{JSON.stringify(err)}"

                done()
        else
            aglio.renderFile argv.i, argv.o, argv, (err, warnings) ->
                if err
                    lineNo = getLineNo err.input, err
                    if lineNo?
                        console.error cErr(">> Line #{lineNo}:") + " #{err.message} (error code #{err.code})"
                    else
                        console.error cErr('>>') + " #{JSON.stringify(err)}"
                    return done err

                logWarnings warnings

                done()
