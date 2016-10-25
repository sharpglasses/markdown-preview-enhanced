katex = require 'katex'
cheerio = require 'cheerio'
path = require 'path'
remarkable = require 'remarkable'
uslug = require 'uslug'
Highlights = require(path.join(atom.getLoadSettings().resourcePath, 'node_modules/highlights/lib/highlights.js'))
{File} = require 'atom'
{mermaidAPI} = require('../dependencies/mermaid/mermaid.min.js')
matter = require('gray-matter')
toc = require('./toc')
{scopeForLanguageName} = require './extension-helper'
customSubjects = require './custom-comment'

mathRenderingOption = atom.config.get('markdown-preview-enhanced.mathRenderingOption')
mathRenderingIndicator = inline: [['$', '$']], block: [['$$', '$$']]
enableWikiLinkSyntax = atom.config.get('markdown-preview-enhanced.enableWikiLinkSyntax')
frontMatterRenderingOption = atom.config.get('markdown-preview-enhanced.frontMatterRenderingOption')
globalMathTypesettingData = {}

TAGS_TO_REPLACE = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    '\'': '&#x27;',
    '\/', '&#x2F;',
    '\\', '&#x5C;',
}
String.prototype.escape = ()->
  this.replace /[&<>"'\/\\]/g, (tag)-> TAGS_TO_REPLACE[tag] || tag

####################################################
## Mermaid
##################################################
loadMermaidConfig = ()->
  # mermaid_config.js
  configPath = path.resolve(atom.config.configDirPath, './markdown-preview-enhanced/mermaid_config.js')
  try
    return require(configPath)
  catch error
    mermaidConfigFile = new File(configPath)
    mermaidConfigFile.create().then (flag)->
      if !flag # already exists
        atom.notifications.addError('Failed to load mermaid_config.js', detail: 'there might be errors in your config file')
        return

      mermaidConfigFile.write """
'use strict'
// config mermaid init call
// http://knsv.github.io/mermaid/#configuration
//
// you can edit the 'config' variable below
// everytime you changed this file, you may need to restart atom.
let config = {
  startOnLoad: false
}

module.exports = config || {startOnLoad: false}
"""
    return {startOnLoad: false}

mermaidAPI.initialize(loadMermaidConfig())

#################################################
## Math
#################################################
atom.config.observe 'markdown-preview-enhanced.mathRenderingOption',
  (option)->
    if option == 'None'
      mathRenderingOption = null
    else
      mathRenderingOption = option

atom.config.observe 'markdown-preview-enhanced.indicatorForMathRenderingInline',
  (indicatorStr)->
    try
      indicators = JSON.parse(indicatorStr).filter (x)->x.length == 2
      mathRenderingIndicator.inline = indicators
    catch error
      console.log error

atom.config.observe 'markdown-preview-enhanced.indicatorForMathRenderingBlock',
  (indicatorStr)->
    try
      indicators = JSON.parse(indicatorStr).filter (x)->x.length == 2
      mathRenderingIndicator.block = indicators
    catch error
      console.log error

atom.config.observe 'markdown-preview-enhanced.enableWikiLinkSyntax',
  (flag)->
    enableWikiLinkSyntax = flag

atom.config.observe 'markdown-preview-enhanced.frontMatterRenderingOption',
  (flag)->
    frontMatterRenderingOption = flag

#################################################
## Remarkable
#################################################
defaults =
  html:         true,        # Enable HTML tags in source
  xhtmlOut:     false,       # Use '/' to close single tags (<br />)
  breaks:       true,        # Convert '\n' in paragraphs into <br>
  langPrefix:   'language-', # CSS language prefix for fenced blocks
  linkify:      true,        # autoconvert URL-like texts to links
  linkTarget:   '',          # set target to open link in
  typographer:  true,        # Enable smartypants and other sweet transforms

md = new remarkable('full', defaults)

atom.config.observe 'markdown-preview-enhanced.breakOnSingleNewline',
  (breakOnSingleNewline)->
    md.set({breaks: breakOnSingleNewline})

atom.config.observe 'markdown-preview-enhanced.enableTypographer', (enableTypographer)->
  md.set({typographer: enableTypographer})


# inline MATH rule
# $...$
# $$...$$
md.inline.ruler.before 'escape', 'math',
  (state, silent)->
    if !mathRenderingOption
      return false

    openTag = null
    closeTag = null
    displayMode = true
    inline = mathRenderingIndicator.inline
    block = mathRenderingIndicator.block

    for b in block
      if state.src.startsWith(b[0], state.pos)
        openTag = b[0]
        closeTag = b[1]
        displayMode = true
        break

    if !openTag
      for i in inline
        if state.src.startsWith(i[0], state.pos)
          openTag = i[0]
          closeTag = i[1]
          displayMode = false
          break

    if !openTag
      return false

    content = null
    end = -1

    i = state.pos + openTag.length
    while i < state.src.length
      if state.src.startsWith(closeTag, i)
        end = i
        break
      else if state.src[i] == '\\'
        i += 1
      i += 1

    if end >= 0
      content = state.src.slice(state.pos + openTag.length, end)
    else
      return false

    if content and !silent
      state.push
        type: 'math'
        content: content.trim(),
        openTag: openTag
        closeTag: closeTag
        displayMode: displayMode

      state.pos += (content.length + openTag.length + closeTag.length)
      return true
    else
      return false

md.renderer.rules.math = (tokens, idx)->
  {content, openTag, closeTag, displayMode} = tokens[idx]
  if !content
    return

  if mathRenderingOption == 'KaTeX'
    if globalMathTypesettingData.isForPreview
      displayModeAttr = if displayMode then 'display-mode' else ''
      if !globalMathTypesettingData.katex_s.length
        return "<span class='katex-exps' #{displayModeAttr}>#{content.escape()}</span>"
      else
        element = globalMathTypesettingData.katex_s.splice(0, 1)[0]
        if element.getAttribute('data-original') == content and element.hasAttribute('display-mode') == displayMode
          return "<span class='katex-exps' data-original=\"#{content}\" data-processed #{displayModeAttr}>#{element.innerHTML}</span>"
        else
          return "<span class='katex-exps' #{displayModeAttr}>#{content.escape()}</span>"

    else # not for preview
      try
        return katex.renderToString content, {displayMode}
      catch error
        return "<span style=\"color: #ee7f49; font-weight: 500;\">#{error}</span>"

  else if mathRenderingOption == 'MathJax'
    text = (openTag + content + closeTag).replace(/\n/g, '')
    tag = if displayMode then 'div' else 'span'

    # if it's for preview
    # we need to save the math expression data to 'data-original' attribute
    # then we compared it with text to see whether the math expression is modified or not.
    if globalMathTypesettingData.isForPreview
      if !globalMathTypesettingData.mathjax_s.length
        return "<#{tag} class=\"mathjax-exps\">#{text.escape()}</#{tag}>"
      else
        element = globalMathTypesettingData.mathjax_s.splice(0, 1)[0]
        if element.getAttribute('data-original') == text and element.tagName.toLowerCase() == tag and element.hasAttribute('data-processed')  # math expression not changed
          return "<#{tag} class=\"mathjax-exps\" data-original=\"#{text}\" data-processed>#{element.innerHTML}</#{tag}>"
        else
          return "<#{tag} class=\"mathjax-exps\">#{text.escape()}</#{tag}>"
    else
      ## this doesn't work
      # element = globalMathTypesettingData.mathjax_s.splice(0, 1)[0]
      # return "<div class=\"mathjax-exps\"> #{element.innerHTML} </div>"
      return text.escape()

# inline [[]] rule
# [[...]]
md.inline.ruler.before 'autolink', 'wikilink',
  (state, silent)->
    if !enableWikiLinkSyntax or !state.src.startsWith('[[', state.pos)
      return false
    content = null
    tag = ']]'
    end = -1

    i = state.pos + tag.length
    while i < state.src.length
      if state.src[i] == '\\'
        i+=1
      else if state.src.startsWith(tag, i)
        end = i
        break
      i+=1

    if end >= 0 # found ]]
      content = state.src.slice(state.pos + tag.length, end)
    else
      return false

    if content and !silent
      state.push
        type: 'wikilink'
        content: content
      state.pos += content.length + 2 * tag.length
      return true
    else
      return false

md.renderer.rules.wikilink = (tokens, idx)->
  {content} = tokens[idx]
  if !content
    return

  splits = content.split('|')
  linkText = splits[0].trim()
  wikiLink = if splits.length == 2 then "#{splits[1].trim()}.md" else "#{linkText}.md" # only support .md file extension

  return "<a href=\"#{wikiLink}\">#{linkText}</a>"

# custom comment
md.block.ruler.before 'code', 'custom-comment',
  (state, start, end, silent)->
    pos = state.bMarks[start] + state.tShift[start]
    max = state.eMarks[start]
    if pos >= max
       return false
    if state.src.startsWith('<!--', pos)
      end = state.src.indexOf('-->', pos + 4)
      if (end >= 0)
        content = state.src.slice(pos + 4, end).trim()

        match = content.match(/(\s|\n)/) # find ' ' or '\n'
        if !match
          firstIndexOfSpace = content.length
        else
          firstIndexOfSpace = match.index

        subject = content.slice(0, firstIndexOfSpace)

        if !customSubjects[subject] # check if it is a valid subject
          # it's not a valid subject, therefore escape it
          state.line = start + 1 + (state.src.slice(pos + 4, end).match(/\n/g)||[]).length
          return true

        rest = content.slice(firstIndexOfSpace+1).trim()

        match = rest.match(/(?:[^\s\n:"']+|"[^"]*"|'[^']*')+/g) # split by space and \newline and : (not in single and double quotezz)

        if match and match.length % 2 == 0
          option = {}
          i = 0
          while i < match.length
            key = match[i]
            value = match[i+1]
            try
              option[key] = JSON.parse(value)
            catch e
              null # do nothing
            i += 2
        else
          option = {}

        state.tokens.push
          type: 'custom'
          subject: subject
          line: state.line
          option: option

        state.line = start + 1 + (state.src.slice(pos + 4, end).match(/\n/g)||[]).length
        return true
      else
        return false

#
# Inject line numbers for sync scroll. Notes:
#
# - We track only headings and paragraphs on first level. That's enougth.
# - Footnotes content causes jumps. Level limit filter it automatically.
#
# YIYI : 这里我不仅仅 map 了 level 0
md.renderer.rules.paragraph_open = (tokens, idx)->
  lineNo = null
  if tokens[idx].lines # /*&& tokens[idx].level == 0*/)
    lineNo = tokens[idx].lines[0]
    return '<p class="sync-line" data-line="' + lineNo + '">'
  return '<p>'


# task list
md.renderer.rules.list_item_open = (tokens, idx)->
  if tokens[idx + 2]
    children = tokens[idx + 2].children
    if !children or !children[0]?.content
      return '<li>'
    line = children[0].content
    if line.startsWith('[ ] ') or line.startsWith('[x] ') or line.startsWith('[X] ')
      children[0].content = line.slice(3)
      checked = !(line[1] == ' ')
      checkBox = "<input type=\"checkbox\" class=\"task-list-item-checkbox\" #{if checked then 'checked' else ''}>"
      level = children[0].level
      # children = [{content: checkBox, type: 'htmltag', level}, ...children]
      children = [{content: checkBox, type: 'htmltag', level}].concat(children)

      tokens[idx + 2].children = children
      return '<li class="task-list-item">'
    return '<li>'
  else
    return '<li>'

# code fences
# modified to support code chunk
# check https://github.com/jonschlinkert/remarkable/blob/875554aedb84c9dd190de8d0b86c65d2572eadd5/lib/rules.js
md.renderer.rules.fence = (tokens, idx, options, env, instance)->
  token = tokens[idx]
  langClass = ''
  langPrefix = options.langPrefix
  langName = ''
  lineStr = ''

  if token.params
    langClass = ' class="' + langPrefix + token.params.escape() + '" ';

  if token.lines
    lineStr = " data-line=\"#{token.lines[0]}\" "

  # get code content
  content = token.content.escape()

  # copied from getBreak function.
  break_ = '\n'
  if idx < tokens.length && tokens[idx].type == 'list_item_close'
    break_ = ''

  return '<pre><code' + langClass + lineStr + '>' + content + '</code></pre>' + break_

# Build offsets for each line (lines can be wrapped)
# That's a bit dirty to process each line everytime, but ok for demo.
# Optimizations are required only for big texts.
buildScrollMap = (markdownPreview)->
  editor = markdownPreview.editor
  markdownHtmlView = markdownPreview.getElement()
  lines = editor.getBuffer().getLines()

  _scrollMap = []
  nonEmptyList = []

  acc = 0

  linesCount = editor.getScreenLineCount()

  for i in [0...linesCount]
    _scrollMap.push(-1)

  nonEmptyList.push(0)
  _scrollMap[0] = 0

  # 把有标记 data-line 的 element 的 offsetTop 记录到 _scrollMap
  # write down the offsetTop of element that has 'data-line' property to _scrollMap
  lineElements = markdownHtmlView.getElementsByClassName('sync-line')

  for i in [0...lineElements.length]
    el = lineElements[i]
    t = el.getAttribute('data-line')
    continue if !t

    t = editor.screenRowForBufferRow(parseInt(t)) # get screen buffer row

    continue if !t

    # this is for ignoring footnote scroll match
    if t < nonEmptyList[nonEmptyList.length - 1]
      el.removeAttribute('data-line')
    else
      nonEmptyList.push(t)

      offsetTop = 0
      while el and el != markdownHtmlView
        offsetTop += el.offsetTop
        el = el.offsetParent

      _scrollMap[t] = Math.round(offsetTop)

  nonEmptyList.push(linesCount)
  _scrollMap.push(markdownHtmlView.scrollHeight)

  pos = 0
  for i in [1...linesCount]
    if _scrollMap[i] != -1
      pos++
      continue

    a = nonEmptyList[pos]
    b = nonEmptyList[pos + 1]
    _scrollMap[i] = Math.round((_scrollMap[b] * (i - a) + _scrollMap[a] * (b - i)) / (b - a))

  return _scrollMap  # scrollMap's length == screenLineCount

# graphType = 'mermaid' | 'plantuml' | 'wavedrom'
checkGraph = (graphType, graphArray=[], preElement, text, option, $, offset=-1)->
  if option.isForPreview
    $preElement = $(preElement)
    if !graphArray.length
      $el = $("<div class=\"#{graphType}\" data-offset=\"#{offset}\">#{text}</div>")
      $el.attr 'data-original', text

      $preElement.replaceWith $el
    else
      element = graphArray.splice(0, 1)[0] # get the first element
      if element.getAttribute('data-original') == text and element.getAttribute('data-processed') == 'true' # graph not changed
        $el = $("<div class=\"#{graphType}\" data-processed=\"true\" data-offset=\"#{offset}\">#{element.innerHTML}</div>")
        $el.attr 'data-original', text

        $preElement.replaceWith $el
      else
        $el = $("<div class=\"#{graphType}\" data-offset=\"#{offset}\">#{text}</div>")
        $el.attr('data-original', text)

        $preElement.replaceWith $el
  else if option.isForEbook
    ### doesn't work...
    if graphType == 'viz'
      Viz = require('../dependencies/viz/viz.js')
      $el = $("<div></div>")
      $el.html(Viz(text))
      $(preElement).replaceWith $el
    else
      $(preElement).replaceWith "<pre>Graph is not supported in EBook</pre>"
    ###
    $el = $("<div class=\"#{graphType}\" #{if graphType in ['wavedrom', 'mermaid'] then "data-offset=\"#{offset}\"" else ''}>Graph is not supported in EBook</div>")
    $el.attr 'data-original', text

    $(preElement).replaceWith $el
  else
    element = graphArray.splice(0, 1)[0]
    if element
      $(preElement).replaceWith "<div class=\"#{graphType}\">#{element.innerHTML}</div>"
    else
      $(preElement).replaceWith "<pre>please wait till preview finishes rendering graph </pre>"

# resolve image path and pre code block...
# check parseMD function, 'option' is the same as the option in paseMD.
resolveImagePathAndCodeBlock = (html, graphData={}, codeChunksData={},  option={})->
  {rootDirectoryPath, projectDirectoryPath} = option

  if !rootDirectoryPath
    return

  $ = cheerio.load(html)
  wavedromOffset = 0
  mermaidOffset = 0

  $('img, a').each (i, imgElement)->
    srcTag = 'src'
    if imgElement.name == 'a'
      srcTag = 'href'

    img = $(imgElement)
    src = img.attr(srcTag)

    if src and
      (!(src.startsWith('http://') or
        src.startsWith('https://') or
        src.startsWith('atom://')  or
        src.startsWith('file://')  or
        src.startsWith('data:image/') or
        src[0] == '#')) and
      (src.startsWith('./') or
        src.startsWith('../') or
        src[0] != '/')
      if !option.isSavingToHTML
        img.attr(srcTag, 'file:///'+path.resolve(rootDirectoryPath,  src))

    else if (src and src[0] == '/')  # absolute path
      if (option.isSavingToHTML)
        img.attr(srcTag, path.relative(rootDirectoryPath, path.resolve(projectDirectoryPath, '.' + src)))
      else
        img.attr(srcTag, 'file:///'+path.resolve(projectDirectoryPath, '.' + src))

  renderCodeBlock = (preElement, text, lang, lineNo=null)->
    highlighter = new Highlights({registry: atom.grammars})
    html = highlighter.highlightSync
            fileContents: text,
            scopeName: scopeForLanguageName(lang)

    highlightedBlock = $(html)
    highlightedBlock.removeClass('editor').addClass('lang-' + lang)

    if lineNo != null
      highlightedBlock.attr({'data-line': lineNo})
      highlightedBlock.addClass('sync-line')

    $(preElement).replaceWith(highlightedBlock)

  # parse eg:
  # {node args:["-v"], output:"html"}
  renderCodeChunk = (preElement, text, parameters, lineNo=null, codeChunksData={})->
    match = parameters.match(/^\{\s*(\"[^\"]*\"|[^\s]*|[^}]*)(.*)}$/)
    lang = match[1].trim()
    parameters = match[2].trim()
    lang = lang.slice(1, lang.length-1).trim() if lang[0] == '"'

    return if !lang

    highlighter = new Highlights({registry: atom.grammars})
    html = highlighter.highlightSync
            fileContents: text,
            scopeName: scopeForLanguageName(lang)

    highlightedBlock = $(html)
    highlightedBlock.removeClass('editor').addClass('lang-' + lang)

    if lineNo != null
      highlightedBlock.attr({'data-line': lineNo})
      highlightedBlock.addClass('sync-line')

    hide = if /\s*hide\s*:\s*true/.test(parameters) then ' hide-chunk ' else ''
    outputDiv = ''

    idMatch = parameters.match(/\s*id\s*:\s*\"([^\"]*)\"/)
    if idMatch and idMatch[1] and codeChunksData[idMatch[1]]
      outputDiv = '<div class="output-div">' + codeChunksData[idMatch[1]].innerHTML + '</div>'

    $el = $("<div class=\"code-chunk #{hide}\" data-cmd=\"#{lang}\">" + '<div class="btn-group"><div class="run-btn btn" style="display: none;"><span>▶︎</span></div>' + "<div class=\"run-all-btn btn\" style=\"display: none;\">all</div></div>" + highlightedBlock + outputDiv + '</div>')
    $el.attr 'data-args', parameters

    $(preElement).replaceWith $el

  $('pre').each (i, preElement)->
    lineNo = null
    if preElement.children[0]?.name == 'code'
      codeBlock = $(preElement).children().first()
      lang = 'text'
      if codeBlock.attr('class')
        lang = codeBlock.attr('class').replace(/^language-/, '') or 'text'
      text = codeBlock.text()

      lineNo = codeBlock.attr('data-line')
    else
      lang = 'text'
      if preElement.children[0]
        text = preElement.children[0].data
      else
        text = ''

    # TODO: remove 'mermaid', only keep {mermaid}
    if lang in ['mermaid', '{mermaid}']
      mermaid.parseError = (err, hash)->
        renderCodeBlock(preElement, err, 'text')

      if mermaidAPI.parse(text.trim())
        checkGraph 'mermaid', graphData.mermaid_s, preElement, text, option, $, mermaidOffset

        mermaidOffset += 1

    else if lang in ['plantuml', 'puml', '{plantuml}', '{puml}']
      checkGraph 'plantuml', graphData.plantuml_s, preElement, text, option, $

    else if lang in ['wavedrom', '{wavedrom}']
      checkGraph 'wavedrom', graphData.wavedrom_s, preElement, text, option, $, wavedromOffset
      wavedromOffset += 1
    else if lang in ['viz', '{viz}']
      checkGraph 'viz', graphData.viz_s, preElement, text, option, $
    else if lang[0] == '{' && lang[lang.length-1] == '}'
      renderCodeChunk(preElement, text, lang, lineNo, codeChunksData)
    else
      renderCodeBlock(preElement, text, lang, lineNo)

  return $.html()

###
# process input string, skip front-matter

if display table
  return {
    content: rest of input string after skipping front matter (but with '\n' included)
    table: string of <table>...</table> generated from data
  }
else
  return {
    content: replace ---\n with ```yaml
    table: '',
  }
###
processFrontMatter = (inputString, hideFrontMatter=false)->
  toTable = (arg)->
    if arg instanceof Array
      tbody = "<tbody><tr>"
      for item in arg
        tbody += "<td>#{toTable(item)}</td>"
      tbody += "</tr></tbody>"

      "<table>#{tbody}</table>"
    else if typeof(arg) == 'object'
      thead = "<thead><tr>"
      tbody = "<tbody><tr>"
      for key of arg
        thead += "<th>#{key}</th>"
        tbody += "<td>#{toTable(arg[key])}</td>"
      thead += "</tr></thead>"
      tbody += "</tr></tbody>"

      "<table>#{thead}#{tbody}</table>"
    else
      arg

  # https://regexper.com/
  r = /^-{3}[\n\r]([\w|\W]+?)[\n\r]-{3}[\n\r]/

  match = r.exec(inputString)

  if match
    if hideFrontMatter or frontMatterRenderingOption[0] == 'n' # hide
      yamlStr = match[0]
      data = matter(yamlStr).data

      content = '\n'.repeat(yamlStr.match(/\n/g)?.length or 0) + inputString.slice(yamlStr.length)
      return {content, table: '', data}
    else if frontMatterRenderingOption[0] == 't' # table
      yamlStr = match[0]
      data = matter(yamlStr).data

      content = '\n'.repeat(yamlStr.match(/\n/g)?.length or 0) + inputString.slice(yamlStr.length)

      # to table
      if typeof(data) == 'object'
        table = toTable(data)
      else
        table = "<pre>Failed to parse YAML.</pre>"

      return {content, table, data}
    else # if frontMatterRenderingOption[0] == 'c' # code block
      yamlStr = match[0]
      data = matter(yamlStr).data

      content = '```yaml\n' + match[1] + '\n```\n' + inputString.slice(yamlStr.length)

      return {content, table: '', data}

  {content: inputString, table: ''}

###
# parse markdown content to html

inputString:         string, required
option = {
  isSavingToHTML:       bool, optional
  isForPreview:         bool, optional
  isForEbook:           bool, optional
  hideFrontMatter:      bool, optional
  markdownPreview:      MarkdownPreviewEnhancedView, optional

  rootDirectoryPath:    string, required
                        the directory path of the markdown file.
  projectDirectoryPath: string, required
}

###
parseMD = (inputString, option={})->
  {markdownPreview} = option

  headings = []

  # toc
  tocNeedUpdate = false
  tocTable = {} # eliminate repeated slug
  tocEnabled = false
  tocStartLine = -1
  tocEndLine = -1
  tocOrdered = false

  # slide
  slideConfigs = []

  # yaml
  yamlConfig = null

  # we won't render the graph that hasn't changed
  graphData = null
  codeChunksData = null
  if markdownPreview
    graphData = markdownPreview.graphData
    codeChunksData = markdownPreview.codeChunksData

  # set globalMathTypesettingData
  # so that we won't render the math expression that hasn't changed
  globalMathTypesettingData = {}
  if markdownPreview
    globalMathTypesettingData.isForPreview = option.isForPreview
    if mathRenderingOption == 'KaTeX'
      globalMathTypesettingData.katex_s = Array.prototype.slice.call markdownPreview.getElement().getElementsByClassName('katex-exps')
    else if mathRenderingOption == 'MathJax'
      globalMathTypesettingData.mathjax_s = Array.prototype.slice.call markdownPreview.getElement().getElementsByClassName('mathjax-exps')

  # check front-matter
  {table:frontMatterTable, content:inputString, data:yamlConfig} = processFrontMatter(inputString, option.hideFrontMatter)

  # overwrite remark heading parse function
  md.renderer.rules.heading_open = (tokens, idx)=>
    line = null
    id = null

    if tokens[idx + 1] and tokens[idx + 1].content
      id = uslug(tokens[idx + 1].content)
      if (tocTable[id] >= 0)
        tocTable[id] += 1
        id = id + '-' + tocTable[id]
      else
        tocTable[id] = 0

      if !tocNeedUpdate
        headings.push({content: tokens[idx + 1].content, level: tokens[idx].hLevel})

    id = if id then "id=#{id}" else ''
    if tokens[idx].lines
      line = tokens[idx].lines[0]
      return "<h#{tokens[idx].hLevel} class=\"sync-line\" data-line=\"#{line}\" #{id}>"

    return "<h#{tokens[idx].hLevel} #{id}>"

  # <!-- subject options... -->
  md.renderer.rules.custom = (tokens, idx)=>
    subject = tokens[idx].subject

    if subject == 'pagebreak' or subject == 'newpage'
      return '<div class="pagebreak"> </div>'
    else if subject == 'toc'
      tocEnabled = true
      if tocStartLine == -1
        tocStartLine = tokens[idx].line

        opt = tokens[idx].option
        if opt.orderedList and opt.orderedList != 0
          tocOrdered = true

      else
        throw 'Only one toc is supported'
    else if (subject == 'tocstop')
      if tocEndLine == -1
        tocEndLine = tokens[idx].line
      else
        throw "Only one toc is supported"
    else if subject == 'slide'
      opt = tokens[idx].option
      opt.line = tokens[idx].line
      slideConfigs.push(opt)
      return '<div class="new-slide"></div>'
    return ''


  html = md.render(inputString)

  # check toc update
  if markdownPreview and tocEnabled
    oldHeadingsLength = markdownPreview.headings.length
    newHeadingsLength = headings.length
    if tocStartLine >= 0 and tocEndLine == -1
      tocNeedUpdate = true
    else if markdownPreview.headings == headings
      tocNeedUpdate = false
    else if oldHeadingsLength != newHeadingsLength
      tocNeedUpdate = true
    else
      for i in [0...headings.length]
        if markdownPreview.headings[i].content != headings[i].content or markdownPreview.headings[i].level != headings[i].level
          tocNeedUpdate = true
          break

    if markdownPreview.tocOrdered != tocOrdered
      markdownPreview.tocOrdered = tocOrdered
      tocNeedUpdate = true

    editor = markdownPreview.editor
    if tocNeedUpdate and editor
      tocObject = toc(headings, tocOrdered)
      buffer = editor.buffer
      if buffer
        if tocEndLine == -1
          tocEndLine = tocStartLine + 1
          buffer.insert([tocStartLine+1, 0], '<!-- tocstop -->\n')

        buffer.setTextInRange([[tocStartLine+1, 0], [tocEndLine, 0]], '\n\n\n')
        buffer.insert([tocStartLine+2, 0], tocObject.content)

        # parse markdown content again
        tocTable = {}
        tocEnabled = false
        tocStartLine = -1
        tocEndLine = -1

        slideConfigs = []

        markdownPreview.parseDelay = Date.now() + 500 # prevent render again
        markdownPreview.editorScrollDelay = Date.now() + 500
        markdownPreview.previewScrollDelay = Date.now() + 500

        {content:inputString} = processFrontMatter(editor.getText(), option.hideFrontMatter)
        html = md.render(inputString)

  markdownPreview?.headings = headings

  html = resolveImagePathAndCodeBlock(html, graphData, codeChunksData, option)
  return {html: frontMatterTable+html, slideConfigs, yamlConfig}

module.exports = {
  parseMD,
  buildScrollMap,
  processFrontMatter
}
