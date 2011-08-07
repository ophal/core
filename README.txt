== Table of Contents ==

I.   What is Ophal?
II.  Roadmap
III. Dependencies


== I. What is Ophal? ==

Ophal is a highly scalable web platform, easy to maintain and extend. It
is not married with a particular technology, just the essence will be
kept on any major change needed to achieve its mission.

The reason for its name is a secret.


== II. Roadmap ==
1. Alpha
  Implement a CGI framework that supports: Modules, Themes, Browser's
  cache, Sessions, File Uploads and Friendly URLs.

2. Beta
  Implement a minimal CMS, using only Lua scripting.

3. Release Candidate
  - Bugs fixing and performance improvements.
  - Start 0.2 branch: Port CGI framework to C, Security improvements and
    Form API.

4. First Stable Release
  Maintenance Release


== III. Dependencies
Ophal depends on the following Lua modules:
- LuaSocket
- LPEG
- LuaFilesystem
- Lua Posix
- Lrexlib PCRE (libpcre3-dev)
