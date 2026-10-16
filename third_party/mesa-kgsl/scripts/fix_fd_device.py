p = '/opt/trixie-cl/root/mesa-26.2.4/src/freedreno/drm/freedreno_device.c'
s = open(p).read()

# 1. allow non-DRM fd (kgsl) to flow through instead of early return
old1 = '''   if (!version) {
      ERROR_MSG("cannot get version: %s", strerror(errno));
      return NULL;
   }
'''
new1 = '''   if (!version)
      DEBUG_MSG("cannot get version: %s - not a DRM device, trying KGSL",
                strerror(errno));
'''
assert old1 in s, 'pattern1'
s = s.replace(old1, new1)

# 2. guard msm compare against NULL version
old2 = '   if (!strcmp(version->name, "msm")) {'
new2 = '   if (version && !strcmp(version->name, "msm")) {'
assert old2 in s, 'pattern2'
s = s.replace(old2, new2)

# 3. drop stale support_use_heap (26.2 renamed to use_heap, default false)
old3 = '''      /* Userspace fences are not supported with KGSL */
      support_use_heap = false;
'''
assert old3 in s, 'pattern3'
s = s.replace(old3, '')

# 4. avoid NULL deref on unsupported-device log
old4 = '      INFO_MSG("unsupported device: %s", version->name);'
new4 = '      INFO_MSG("unsupported device: %s", version ? version->name : "(unknown)");'
assert old4 in s, 'pattern4'
s = s.replace(old4, new4)

open(p, 'w').write(s)
print('FIXED')
