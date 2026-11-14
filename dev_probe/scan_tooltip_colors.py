import os, re

root = 'lib'
rows = []
for dirpath, _, files in os.walk(root):
    for f in files:
        if not f.endswith('.dart'):
            continue
        p = os.path.join(dirpath, f)
        s = open(p, encoding='utf-8').read()
        for m in re.finditer(r'\bTooltip\s*\(', s):
            i = m.end()
            depth = 1
            while i < len(s) and depth > 0:
                if s[i] == '(':
                    depth += 1
                elif s[i] == ')':
                    depth -= 1
                i += 1
            body = s[m.start():i]
            line = s[:m.start()].count('\n') + 1
            bg = re.findall(r'\bcolor:\s*([^,\n]+)', body)
            tsc = re.findall(r'textStyle:\s*(?:const\s*)?TextStyle\(([^)]*)\)', body)
            tscol = []
            for t in tsc:
                tscol += re.findall(r'color:\s*([^,\n]+)', t)
            rows.append((p, line, 'DECO' if 'decoration' in body else '----', bg[:3], tscol[:2]))

for r in rows:
    print(f'{r[0]}:{r[1]}\t{r[2]}\tbg={r[3]}\tts={r[4]}')
print('total', len(rows))
