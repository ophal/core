== Table of Contents ==

I.   What is Ophal?
II.  Roadmap
III. Dependencies


== I. What is Ophal? ==

Ophal is a highly scalable web platform, easy to maintain, learn, extend
and open to improvements.

The reason for its name is a secret.


== II. Roadmap ==
1. Alpha
  Implement a web development framework that supports: Modules, Themes, Browser's
  cache, Sessions, File Uploads(RFCs 1867 & 2388) and Friendly URLs.

2. Beta
  Implement a minimal CMS: content CRUD in a DBMS.

3. Release Candidate
  - Bugs fixing and performance improvements.
  - Start 0.2 branch: Port core to C, Security improvements and
    Form API.

4. First Stable Release
  Maintenance Release


== III. Dependencies
Ophal has the following dependencies:
- Seawolf (http://gitorious.org/ophal/seawolf)
- Lua-CGIC (http://gitorious.org/ophal/cgic)
- LuaSocket
- LPEG
- LuaFilesystem
- Lrexlib PCRE (libpcre3-dev)
- LuaDBI
- luuid
- luajson

