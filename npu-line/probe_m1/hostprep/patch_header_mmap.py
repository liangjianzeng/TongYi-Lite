# [C32] Rewrite BINVARSTART/BINVAREND/BINLEN in a copied QnnWrapperUtils.hpp to the
# runtime mmap registry (qnn_mmap_data.cpp), so model data stays OUT of the ELF.
import re, sys
p = sys.argv[1]
s = open(p, 'r', encoding='utf-8').read()

decl = ('#ifdef __cplusplus\nextern "C" { void* qnn_mmap_get(const char*); unsigned long long qnn_mmap_len(const char*); }\n#endif\n')

pat = re.compile(r'#define BINVARSTART\(NAME\).*?\}\)\n\s*#define BINVAREND\(NAME\).*?\}\)\n\s*#define BINLEN\(NAME\).*?\}\)\n', re.S)
assert pat.search(s), 'macro block not found'
repl = (decl +
        '#define BINVARSTART(NAME) (qnn_mmap_get(#NAME))\n'
        '#define BINVAREND(NAME)   ((void*)((const uint8_t*)qnn_mmap_get(#NAME) + qnn_mmap_len(#NAME)))\n'
        '#define BINLEN(NAME)      ((uint32_t)qnn_mmap_len(#NAME))\n')
s = pat.sub(repl, s)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('HEADER_PATCHED', p)
