"""Convert a .docx into docxlike source; what it cannot carry is listed in the report.

Usage: docx2docxlike.py IN.docx OUT.tex [--font-map MAP.json] [--report REPORT.json]
MAP.json maps font names to files: {"SimSun": {"file": "simsun.ttc", "path": "/dir/", "index": 0, "asian": true}};
"bold", "italic" and "bolditalic" name the other faces when there are files for them.
A map of the form {"*": {"system": true}} keeps every Word family name and lets the
compile host resolve installed fonts; it does not substitute families.
"""
import argparse,json,math,re,sys,zipfile,collections
from pathlib import Path
import xml.etree.ElementTree as ET

W='{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
R='{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
A='{http://schemas.openxmlformats.org/drawingml/2006/main}'
WP='{http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing}'
PIC='{http://schemas.openxmlformats.org/drawingml/2006/picture}'
V='{urn:schemas-microsoft-com:vml}'
MC='{http://schemas.openxmlformats.org/markup-compatibility/2006}'
EMU=12700  # per bp
M='{http://schemas.openxmlformats.org/officeDocument/2006/math}'
def q(n): return W+n
def whole(s):
    # OOXML integer attributes; some writers put decimals there ("4.0")
    return round(float(s))
def val(e,name='val',default=None):
    if e is None: return default
    return e.get(q(name),default)
def on(e):
    """OOXML on/off property: present without val, or val not false/0/off."""
    if e is None: return None
    v=e.get(q('val'))
    return v is None or v not in ('0','false','off')
def bp(tw): return f'{float(tw)/20:g}bp'
def hp(h): return f'{whole(h)/2:g}bp'


# Office math (OMML) to LaTeX for unicode-math; letters are italic by default as in Word
MATH_SPECIAL={'{':r'\{','}':r'\}','#':r'\#','$':r'\$','%':r'\%','&':r'\&','_':r'\_','\\':r'\backslash ','~':r'\sim ','^':r'\hat{}'}
NARY={'∑':r'\sum','∏':r'\prod','∐':r'\coprod','∫':r'\int','∬':r'\iint','∭':r'\iiint','∮':r'\oint','∯':r'\oiint',
      '⋃':r'\bigcup','⋂':r'\bigcap','⋁':r'\bigvee','⋀':r'\bigwedge','⨁':r'\bigoplus','⨂':r'\bigotimes'}
DELIM={'(':'(',')':')','[':'[',']':']','{':r'\{','}':r'\}','|':'|','‖':r'\|','⟨':r'\langle','⟩':r'\rangle',
       '〈':r'\langle','〉':r'\rangle','⌊':r'\lfloor','⌋':r'\rfloor','⌈':r'\lceil','⌉':r'\rceil','':'.'}
ACCENT={'\u0302':r'\hat','\u0303':r'\tilde','\u0304':r'\bar','\u0305':r'\overline','\u0307':r'\dot','\u0308':r'\ddot',
        '\u20d7':r'\vec','\u0306':r'\breve','\u0301':r'\acute','\u0300':r'\grave','\u030c':r'\check','\u20d6':r'\overleftarrow'}
def mval(e,name,default=None):
    if e is None: return default
    x=e.find(M+name)
    return x.get(M+'val',default) if x is not None else default
class Math:
    def __init__(self,rep): self.rep=rep
    def arg(self,e,name):
        x=e.find(M+name)
        return self.seq(x) if x is not None else ''
    def seq(self,e): return ''.join(self.node(c) for c in e)
    def text(self,t,sty):
        out=''.join(MATH_SPECIAL.get(ch,ch) for ch in t)
        if sty=='p' and out.strip(): return r'\mathrm{'+out+'}'
        if sty=='b': return r'\mathbf{'+out+'}'
        if sty=='bi': return r'\mathbfit{'+out+'}'
        return out
    def node(self,c):
        n=c.tag.replace(M,'') if c.tag.startswith(M) else None
        if n is None:
            if c.tag==W+'r':   # a Word run inside math: plain text
                t=''.join(x.text or '' for x in c.findall(W+'t'))
                return r'\text{'+''.join(MATH_SPECIAL.get(ch,ch) for ch in t)+'}' if t else ''
            return ''
        if n in ('rPr','ctrlPr','fPr','sSubPr','sSupPr','sSubSupPr','sPrePr','radPr','naryPr','dPr','funcPr','limLowPr',
                 'limUppPr','accPr','barPr','groupChrPr','boxPr','borderBoxPr','mPr','eqArrPr','phantPr','oMathParaPr','argPr'): return ''
        if n=='r':
            rpr=c.find(M+'rPr'); t=''.join(x.text or '' for x in c.findall(M+'t'))
            if rpr is not None and rpr.find(M+'nor') is not None: return r'\text{'+''.join(MATH_SPECIAL.get(ch,ch) for ch in t)+'}'
            return self.text(t,mval(rpr,'sty','i'))
        if n in ('e','num','den','sub','sup','deg','fName','lim'): return self.seq(c)
        if n=='f':
            num,den=self.arg(c,'num'),self.arg(c,'den'); t=mval(c.find(M+'fPr'),'type','bar')
            if t=='lin': return f'{{{num}}}/{{{den}}}'
            if t=='noBar': return rf'\genfrac{{}}{{}}{{0pt}}{{}}{{{num}}}{{{den}}}'
            return rf'\frac{{{num}}}{{{den}}}'
        if n in ('sSub','sSup','sSubSup'):
            base=self.arg(c,"e")
            # a base that itself ends in a script gets an empty group: unicode-math reports {{\hat x}_i}_j as a
            # double subscript
            if base.rstrip().endswith('}') and re.search(r'[_^]\{[^{}]*\}$',base.rstrip()): base+='{}'
            if n=='sSub': return f'{{{base}}}_{{{self.arg(c,"sub")}}}'
            if n=='sSup': return f'{{{base}}}^{{{self.arg(c,"sup")}}}'
            return f'{{{base}}}_{{{self.arg(c,"sub")}}}^{{{self.arg(c,"sup")}}}'
        if n=='sPre': return f'{{}}_{{{self.arg(c,"sub")}}}^{{{self.arg(c,"sup")}}}{{{self.arg(c,"e")}}}'
        if n=='rad':
            hide=mval(c.find(M+'radPr'),'degHide','0') in ('1','on','true')
            deg=self.arg(c,'deg')
            return rf'\sqrt{{{self.arg(c,"e")}}}' if hide or not deg else rf'\sqrt[{deg}]{{{self.arg(c,"e")}}}'
        if n=='nary':
            pr=c.find(M+'naryPr'); ch=mval(pr,'chr','∫')
            op=NARY.get(ch)
            if op is None: op=r'\mathop{'+ch+'}'
            loc=mval(pr,'limLoc','undOvr' if ch in '∑∏∐⋃⋂⋁⋀' else 'subSup')
            op+=r'\limits' if loc=='undOvr' else r'\nolimits'
            sub='' if mval(pr,'subHide','0') in ('1','on','true') else self.arg(c,'sub')
            sup='' if mval(pr,'supHide','0') in ('1','on','true') else self.arg(c,'sup')
            return op+(f'_{{{sub}}}' if sub else '')+(f'^{{{sup}}}' if sup else '')+'{'+self.arg(c,'e')+'}'
        if n=='d':
            pr=c.find(M+'dPr')
            beg,end,sep=mval(pr,'begChr','('),mval(pr,'endChr',')'),mval(pr,'sepChr','|')
            def dl(x):
                if x in DELIM: return DELIM[x]
                self.rep.add(f'math delimiter {x!r} (parenthesis used)'); return '('
            parts=[self.seq(x) for x in c.findall(M+'e')]
            mid=(r'\middle'+dl(sep)) if sep else ''
            return r'\left'+dl(beg)+mid.join(parts)+r'\right'+dl(end)
        if n=='func':
            name=self.arg(c,'fName')
            m=re.fullmatch(r'\\mathrm\{([A-Za-z]+)\}',name)
            name=rf'\operatorname{{{m.group(1)}}}' if m else name
            return name+r'\,{'+self.arg(c,'e')+'}' if not name.startswith(r'\operatorname') else name+'{'+self.arg(c,'e')+'}'
        if n=='limLow':
            base=self.arg(c,'e'); lim=self.arg(c,'lim')
            if re.fullmatch(r'\\operatorname\{\w+\}|\\mathrm\{\w+\}',base): return rf'\mathop{{{base}}}\limits_{{{lim}}}'
            return rf'\underset{{{lim}}}{{{base}}}'
        if n=='limUpp': return rf'\overset{{{self.arg(c,"lim")}}}{{{self.arg(c,"e")}}}'
        if n=='acc':
            ch=mval(c.find(M+'accPr'),'chr','\u0302')
            return ACCENT.get(ch,r'\hat')+'{'+self.arg(c,'e')+'}'
        if n=='bar':
            return (r'\underline{' if mval(c.find(M+'barPr'),'pos','bot')=='bot' else r'\overline{')+self.arg(c,'e')+'}'
        if n=='groupChr':
            pr=c.find(M+'groupChrPr'); ch=mval(pr,'chr','\u23df'); pos=mval(pr,'pos','bot')
            e=self.arg(c,'e')
            if ch in ('\u23df','\u23de') or True:
                return (r'\underbrace{' if pos=='bot' else r'\overbrace{')+e+'}'
        if n=='box': return '{'+self.arg(c,'e')+'}'
        if n=='borderBox': return r'\boxed{'+self.arg(c,'e')+'}'
        if n=='phant': return r'\phantom{'+self.arg(c,'e')+'}'
        if n=='m':
            rows=[' & '.join(self.seq(e) for e in mr.findall(M+'e')) for mr in c.findall(M+'mr')]
            return r'\begin{matrix}'+r' \\ '.join(rows)+r'\end{matrix}'
        if n=='eqArr':
            rows=[self.seq(e) for e in c.findall(M+'e')]
            return r'\begin{gathered}'+r' \\ '.join(rows)+r'\end{gathered}'
        if n=='oMath': return self.seq(c)
        self.rep.add(f'math {n} (left out)')
        return ''

class Report:
    def __init__(self): self.items=collections.Counter()
    def add(self,what): self.items[what]+=1

class ParagraphTeX(str):
    """A rendered paragraph, retained as such while grouping adjacent borders."""


class Converter:
    TAB = r'\docxinsert[tab]{}'

    @staticmethod
    def font_options(keys, style=None):
        result=[f'style={style}'] if style else []
        font=[];advanced=[]
        for key in keys:
            name,sep,value=key.partition('=')
            if name=='language':result.append(key)
            elif name=='shading':result.append('borders-and-shading={apply-to=text,shading='+value+'}')
            elif name in ('scale','character-spacing','position','kerning-for-fonts','snap-to-grid-when-document-grid-is-defined'):
                advanced.append(('spacing='+value) if name=='character-spacing' else key)
            elif name=='underline-color' and value=='auto':font.append('underline-color=automatic')
            else:font.append(key)
        if advanced:font.append('advanced={character-spacing={'+','.join(advanced)+'}}')
        if font:result.append('font={'+','.join(font)+'}')
        return result

    @staticmethod
    def font_requires_backend(keys):
        if any(key.partition('=')[0].startswith('complex-script-') for key in keys):return True
        for key in keys:
            name,sep,value=key.partition('=')
            if name=='size' and re.fullmatch(r'[-+]?\d+(?:\.\d+)?bp',value):
                if not 1<=float(value[:-2])<=1638:return True
        if 'underline-style=none' in keys and any(key.startswith('underline-color=') for key in keys):return True
        if any(key in ('all-caps','all-caps=true') for key in keys) and any(key in ('small-caps','small-caps=true') for key in keys):return True
        return False

    @staticmethod
    def paragraph_options(keys):
        result=[]
        for key in keys:
            name,sep,value=key.partition('=')
            if name=='border':result.append('borders-and-shading={borders='+value+'}')
            elif name=='shading':result.append('borders-and-shading={shading='+value+'}')
            elif name=='font':
                # Paragraph-mark properties are a complete-paragraph direct format.
                result.append(key)
            elif name=='tabs':
                stops=re.findall(r'\{position=([^,{}]+),alignment=(left|center|right)(?:,leader=([^{}]+))?\}',value)
                operations=['clear-all']
                for position,alignment,leader in stops:
                    number={'':'1','none':'1','dot':'2','hyphen':'3','underscore':'4'}.get(leader)
                    if number is None:
                        raise ValueError('OOXML-only tab leaders require the programming paragraph route')
                    operations.extend(('tab-stop-position='+position,'alignment='+alignment,'leader='+number,'set'))
                else:
                    result.append('tabs={'+','.join(operations)+'}')
            else:result.append(key)
        return result

    @staticmethod
    def author_paragraph(keys):
        """Group the known pPr adapter records once, before writing author controls."""
        scalar={};groups={};line_break=[];character_spacing=[]
        for key in keys:
            name,sep,value=key.partition('=')
            if name in ('indentation','spacing','pagination'):
                groups.setdefault(name,[]).append(value[1:-1])
            elif name=='snap-to-grid-when-document-grid-is-defined':
                groups.setdefault('spacing',[]).append(key)
            elif name=='asian-typography':
                inner=value[1:-1]
                (line_break if inner.startswith('allow-latin-text-to-wrap-in-the-middle-of-a-word=') else character_spacing).append(inner)
            else:
                scalar[name]=key
        result=list(scalar.values())
        for name,parts in groups.items():
            joined=','.join(parts)
            if name=='pagination':
                result.append('line-and-page-breaks={pagination={'+joined.replace('widow-control=','widow-orphan-control=')+'}}')
            else:
                result.append(name+'={'+joined+'}')
        asian=[]
        if line_break:asian.append('line-break={'+','.join(line_break)+'}')
        if character_spacing:asian.append('character-spacing={'+','.join(character_spacing)+'}')
        if asian:result.append('asian-typography={'+','.join(asian)+'}')
        return result
    def __init__(self,path,font_map=None,media_dir=None,media_prefix='',paragraph_defaults=None):
        self.z=zipfile.ZipFile(path); self.rep=Report(); self.font_map=font_map or {}
        self.paragraph_defaults=paragraph_defaults
        if paragraph_defaults is not None:
            if not isinstance(paragraph_defaults,dict) or set(paragraph_defaults)!={'spacing'}:
                raise ValueError('paragraph defaults must contain one spacing object')
            spacing=paragraph_defaults['spacing']
            if not isinstance(spacing,dict) or set(spacing)!={'before','after','line','lineRule'}:
                raise ValueError('spacing must specify before, after, line and lineRule (OOXML units)')
            if spacing['lineRule'] not in ('auto','exact','atLeast'):
                raise ValueError('lineRule must be auto, exact or atLeast')
            if any(type(spacing[k]) is not int or not 0<=spacing[k]<=31680 for k in ('before','after','line')) or spacing['line']==0:
                raise ValueError('spacing values must be integer OOXML units in 0..31680; line must be positive')
        self.doc=self.xml('word/document.xml'); self.styles=self.xml('word/styles.xml'); self.settings=self.xml('word/settings.xml')
        self.theme=self.xml('word/theme/theme1.xml'); self.rels=self.load_rels()
        self.media_dir=media_dir; self.media_prefix=media_prefix; self.part_rels=None; self.anchors=[]; self.story='body'
        self.compat=15; self.joined=''; self.section_list=[]; self.no_expand_shift_return=False
        self.fonts_used=set(); self.languages={}; self.style_names={}; self.fields=[]; self.blocks=[]
        self.style_lists={}; self.used_nums=set(); self.notes_xml={}; self.used_notes=set(); self.numbering=self.xml('word/numbering.xml')
        self.default_par_style=next((s.get(q('styleId')) for s in (self.styles.findall(q('style')) if self.styles is not None else [])
                                     if s.get(q('type'))=='paragraph' and s.get(q('default')) in ('1','true')),None)
        self.default_char_style=next((s.get(q('styleId')) for s in (self.styles.findall(q('style')) if self.styles is not None else [])
                                      if s.get(q('type'))=='character' and s.get(q('default')) in ('1','true')),None)
        self.styles_by_id={s.get(q('styleId')):s for s in (self.styles.findall(q('style')) if self.styles is not None else [])}
        self.paragraph_font_flags=None
    def xml(self,name):
        try: return ET.fromstring(self.z.read(name))
        except KeyError: return None
    def load_rels(self,part='document.xml'):
        r=self.xml(f'word/_rels/{part}.rels'); out={}
        if r is not None:
            for e in r: out[e.get('Id')]=e.get('Target')
        return out
    # pictures: the image is copied next to the .tex; what LaTeX cannot include keeps its size as an empty box
    GRAPHIC_EXT=('.png','.jpg','.jpeg','.pdf')
    def image(self,rid,w,h):
        target=(self.part_rels or self.rels).get(rid)
        size=f'width={w/EMU:g}bp,height={h/EMU:g}bp'
        box=f'\\hbox to{w/EMU:g}bp{{\\vrule height{h/EMU:g}bp width0pt\\hfil}}'
        if not target: self.rep.add('picture without its image part (empty box)'); return box
        name='word/'+target if not target.startswith('/') else target[1:]
        ext=Path(name).suffix.lower()
        if ext not in self.GRAPHIC_EXT:
            self.rep.add(f'picture in {ext or "unknown"} format (empty box of its size)'); return box
        if self.media_dir is None: return box
        try: data=self.z.read(name)
        except KeyError: self.rep.add('picture without its image part (empty box)'); return box
        out=self.media_dir/Path(name).name
        out.parent.mkdir(parents=True,exist_ok=True); out.write_bytes(data)
        self.uses_graphics=True
        return f'\\includegraphics[{size}]{{{self.media_prefix}{Path(name).name}}}'
    def drawing(self,d):
        inline=d.find(WP+'inline'); anchor=d.find(WP+'anchor'); e=inline if inline is not None else anchor
        if e is None: return None
        ext=e.find(WP+'extent'); w,h=whole(ext.get('cx') or 0),whole(ext.get('cy') or 0)
        gd=e.find(f'{A}graphic/{A}graphicData')
        blip=gd.find(f'.//{A}blip') if gd is not None else None
        uri=gd.get('uri','') if gd is not None else ''
        if blip is not None and uri.endswith('/picture'):
            body=self.image(blip.get(R+'embed'),w,h)
        else:
            kind=uri.rsplit('/',1)[-1] or 'graphic'
            self.rep.add(f'drawing {kind} (empty box of its size)')
            body=f'\\hbox to{w/EMU:g}bp{{\\vrule height{h/EMU:g}bp width0pt\\hfil}}'
        rotation=''
        transform=gd.find(f'.//{A}xfrm') if gd is not None else None
        if transform is not None:
            angle=whole(transform.get('rot') or 0) % 21600000
            if angle:
                if inline is not None and blip is not None and uri.endswith('/picture') and angle in (5400000,10800000,16200000):
                    rotation='size={rotate={rotation='+str(angle//60000)+'}}'
                else:
                    self.rep.add(f'picture rotation {angle/60000:g} degrees (not applied)')
            if transform.get('flipH') in ('1','true') or transform.get('flipV') in ('1','true'):
                self.rep.add('picture flip (not applied)')
        if inline is not None:
            options='={layout={'+rotation+'}}' if rotation else ''
            return '\\docxinsert[pictures'+options+']{'+body+'}'
        is_image=blip is not None and uri.endswith('/picture')
        wrap_none=anchor.find(WP+'wrapNone') is not None or not any(anchor.find(WP+x) is not None for x in ('wrapSquare','wrapTight','wrapThrough','wrapTopAndBottom'))
        if wrap_none:
            # in front of or behind the text: Word does not move the text for it
            self.rep.add('picture or shape in front of or behind text (not placed)'); return ''
        if self.story!='body':
            # docxlike wraps text only around objects between body paragraphs
            if is_image: self.rep.add(f'anchored picture in a {self.story} (placed inline)'); return '\\docxinsert[pictures]{'+body+'}'
            self.rep.add(f'anchored shape in a {self.story} (not placed)'); return ''
        wrapping=[];position=[]
        top_bottom=anchor.find(WP+'wrapTopAndBottom') is not None
        if top_bottom: wrapping.append('wrapping-style=top-and-bottom')
        elif anchor.find(WP+'wrapSquare') is not None or anchor.find(WP+'wrapTight') is not None or anchor.find(WP+'wrapThrough') is not None:
            ws=anchor.find(WP+'wrapSquare'); ws=ws if ws is not None else (anchor.find(WP+'wrapTight') if anchor.find(WP+'wrapTight') is not None else anchor.find(WP+'wrapThrough'))
            if ws.tag!=WP+'wrapSquare': self.rep.add('picture wrapping tight/through (set as square)')
            wrapping.append('wrapping-style=square')
            wrapping.append('wrap-text='+{'bothSides':'both-sides','left':'left-only','right':'right-only','largest':'largest-only'}.get(ws.get('wrapText','bothSides'),'both-sides'))
        sides=(('top','T'),('bottom','B')) if top_bottom else (('left','L'),('right','R'),('top','T'),('bottom','B'))
        dist=[f'{k}={whole(anchor.get("dist"+K) or 0)/EMU:g}bp' for k,K in sides]
        wrapping.append('distance-from-text={'+','.join(dist)+'}')
        ph=anchor.find(WP+'positionH')
        if ph is not None:
            rel={'margin':'margin','page':'page','column':'column'}.get(ph.get('relativeFrom'),None)
            if rel is None: self.rep.add(f'picture horizontal position relative to {ph.get("relativeFrom")} (margin used)'); rel='margin'
            al=ph.find(WP+'align'); off=ph.find(WP+'posOffset')
            pos=al.text if al is not None and al.text in ('left','center','right') else f'{whole(off.text)/EMU:g}bp' if off is not None else 'left'
            if al is not None and al.text not in ('left','center','right'): self.rep.add(f'picture horizontal align {al.text} (left used)')
            if pos in ('left','center','right'):
                position.append(f'horizontal={{alignment={"centered" if pos=="center" else pos},relative-to={rel}}}')
            else:
                position.append(f'horizontal={{absolute-position={pos},to-the-right-of={rel}}}')
        pv=anchor.find(WP+'positionV')
        if pv is not None:
            rel={'paragraph':'paragraph','margin':'margin','page':'page','line':'paragraph'}.get(pv.get('relativeFrom'),None)
            if rel is None or pv.get('relativeFrom')=='line': self.rep.add(f'picture vertical position relative to {pv.get("relativeFrom")} (paragraph used)'); rel='paragraph'
            off=pv.find(WP+'posOffset')
            if off is None: self.rep.add('picture vertical align (offset 0 used)')
            position.append(f'vertical={{absolute-position={whole(off.text)/EMU if off is not None else 0:g}bp,below={rel}}}')
        # an anchored picture goes before the paragraph that holds its anchor
        layout=['text-wrapping={'+','.join(wrapping)+'}']
        if position: layout.append('position={'+','.join(position)+'}')
        self.anchors.append('\\docxinsert[pictures={layout={'+','.join(layout)+'}}]{'+body+'}')
        return ''
    def vml_picture(self,pict):
        shape=pict.find(f'.//{V}shape'); img=pict.find(f'.//{V}imagedata')
        if shape is None or img is None: return None
        style=dict(x.split(':',1) for x in (shape.get('style') or '').split(';') if ':' in x)
        def length(v):
            m=re.match(r'([\d.]+)(pt|in|cm|mm|px)?',v or '')
            if not m: return 0
            f={'pt':1,'in':72,'cm':72/2.54,'mm':72/25.4,'px':0.75,None:1}[m.group(2)]
            return float(m.group(1))*f*EMU
        w,h=length(style.get('width')),length(style.get('height'))
        if style.get('position')=='absolute': self.rep.add('VML picture positioned absolutely (placed inline)')
        return '\\docxinsert[pictures]{'+self.image(img.get(R+'id'),w,h)+'}'

    def theme_font(self,name):
        if self.theme is None: return None
        major='major' in name.lower(); script='ea' if 'eastasia' in name.lower() else 'latin'
        group=self.theme.find(f'.//{A}{"majorFont" if major else "minorFont"}')
        if group is None: return None
        node=group.find(f'{A}{script}')
        f=node.get('typeface') if node is not None else None
        if not f and script=='ea':
            # an empty <a:ea> means the typeface listed for the script
            for x in group.findall(f'{A}font'):
                if x.get('script')==self.ea_script(): return x.get('typeface')
        return f or None
    def ea_script(self):
        lang=None
        if self.styles is not None:
            e=self.styles.find(f'{q("docDefaults")}/{q("rPrDefault")}/{q("rPr")}/{q("lang")}')
            if e is not None: lang=e.get(q('eastAsia'))
        return {'zh-TW':'Hant','zh-HK':'Hant','zh-MO':'Hant','ja-JP':'Jpan','ko-KR':'Hang'}.get(lang or '','Hans')
    def fonts(self,rf):
        """latin, asian font names from w:rFonts."""
        if rf is None: return None,None
        latin=rf.get(q('ascii')) or rf.get(q('hAnsi'))
        if not latin and rf.get(q('asciiTheme')): latin=self.theme_font(rf.get(q('asciiTheme')))
        asian=rf.get(q('eastAsia'))
        if not asian and rf.get(q('eastAsiaTheme')):
            asian=self.theme_font(rf.get(q('eastAsiaTheme')))
            if not asian: self.rep.add('rPr/rFonts eastAsiaTheme without a typeface in the theme')
        return latin,asian

    HIGHLIGHT={'yellow':'yellow','green':'bright-green','cyan':'turquoise','magenta':'pink','blue':'blue','red':'red',
               'darkBlue':'dark-blue','darkCyan':'teal','darkGreen':'green','darkMagenta':'violet','darkRed':'dark-red',
               'darkYellow':'dark-yellow','darkGray':'gray-50','lightGray':'gray-25','black':'black','none':'no-color'}
    RPR_SKIP={'noProof','webHidden','rPrChange','ins','del','cs'}
    def font_style_flags(self,style_id=None,base=None,character=False):
        names=('b','i','bCs','iCs')
        if base is None:
            default=self.styles.find(f'{q("docDefaults")}/{q("rPrDefault")}/{q("rPr")}') if self.styles is not None else None
            flags={name:bool(on(default.find(q(name)))) if default is not None else False for name in names}
        else:flags=dict(base)
        chain=[];seen=set()
        while style_id in self.styles_by_id and style_id not in seen and len(chain)<20:
            seen.add(style_id);style=self.styles_by_id[style_id];chain.append(style)
            style_id=val(style.find(q('basedOn')))
        inherited={}
        for style in reversed(chain):
            properties=style.find(q('rPr'))
            if properties is not None:
                for name in names:
                    element=properties.find(q(name))
                    if element is not None:inherited[name]=on(element)
        if character:
            # The character style's effective value is relative to document
            # defaults, not an unconditional XOR with true. Preserve each bit
            # absent from the character style's basedOn chain.
            defaults=self.font_style_flags()
            for name,value in inherited.items():
                if value!=defaults[name]:flags[name]=not flags[name]
        else:flags.update(inherited)
        return flags
    def rpr(self,e,allow_style=False,base_font_flags=None):
        keys=[]; style=None
        if e is None: return keys,style
        b=i=bcs=ics=None
        for c in e:
            n=c.tag.replace(W,'')
            if n=='rStyle': style=val(c)
            elif n=='rFonts':
                if c.get(q('cs')): keys.append(f'complex-script-font={c.get(q("cs"))}')
                lat,asi=self.fonts(c)
                if lat: keys.append(f'latin-text-font={lat}'); self.fonts_used.add((lat,False))
                if asi: keys.append(f'asian-text-font={asi}'); self.fonts_used.add((asi,True))
            elif n=='sz': keys.append(f'size={hp(val(c))}')
            elif n=='szCs': keys.append(f'complex-script-size={hp(val(c))}')
            elif n=='bCs': bcs=on(c)
            elif n=='iCs': ics=on(c)
            elif n=='b': b=on(c)
            elif n=='i': i=on(c)
            elif n=='color':
                v=val(c)
                if v is not None: keys.append('font-color=automatic' if v=='auto' else f'font-color={v}')
            elif n=='u':
                v=val(c,default='single')
                if v=='none': keys.append('underline-style=none')
                elif v=='words': keys.append('underline-style=words-only')
                else:
                    keys.append('underline-style=single')
                    if v!='single': self.rep.add(f'rPr/u val={v} (set as single)')
                if c.get(q('color')): keys.append('underline-color=automatic' if c.get(q('color'))=='auto' else f'underline-color={c.get(q("color"))}')
            elif n=='spacing':
                tw=whole(val(c,default='0'))
                keys.append(f'character-spacing={{spacing={"expanded" if tw>0 else "condensed"},by={abs(tw)/20:g}bp}}' if tw else 'character-spacing={spacing=normal}')
            elif n=='caps': keys.append('all-caps' if on(c) else 'all-caps=false')
            elif n=='smallCaps': keys.append('small-caps' if on(c) else 'small-caps=false')
            elif n=='vanish': keys.append('hidden' if on(c) else 'hidden=false')
            elif n=='w': keys.append(f'scale={whole(val(c,default="100"))}')
            elif n=='position':
                v=whole(val(c,default='0'))
                keys.append('position={position='+('raised' if v>0 else 'lowered')+f',by={abs(v)/2:g}bp}}' if v else 'position={position=normal}')
            elif n=='vertAlign':
                v=val(c)
                if v=='superscript': keys.append('superscript')
                elif v=='subscript': keys.append('subscript')
                elif v=='baseline': keys.extend(('superscript=false','subscript=false'))
            elif n=='kern':
                v=whole(val(c,default='0')); keys.append(f'kerning-for-fonts={min(v/2,1638):g}bp' if v else 'kerning-for-fonts=false')  # 1638 pt is Word's largest
            elif n=='highlight':
                v=val(c)
                if v in self.HIGHLIGHT: keys.append(f'text-highlight-color={self.HIGHLIGHT[v]}')
                else: self.rep.add(f'rPr/highlight val={v}')
            elif n=='shd':
                f=c.get(q('fill'))
                if f and f!='auto': keys.append(f'shading={{fill={f}}}')
                if val(c) not in (None,'clear','nil'): self.rep.add('rPr/shd pattern (fill kept)')
            elif n=='snapToGrid': keys.append(f'snap-to-grid-when-document-grid-is-defined={"true" if on(c) else "false"}')
            elif n=='lang':
                language=val(c)
                if language:
                    if language.lower()!='auto' and re.fullmatch(r'[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*',language):
                        parts=language.split('-')
                        normalized=[parts[0].lower()];extension=False
                        for part in parts[1:]:
                            extension=extension or len(part)==1
                            normalized.append(part.lower() if extension else part.title() if len(part)==4 and part.isalpha()
                                              else part.upper() if len(part)==2 and part.isalpha() else part.lower())
                        language='-'.join(normalized)
                        self.languages.setdefault(language.lower(),language)
                        keys.append('language={'+language+'}')
                    else:self.rep.add(f'rPr/lang val={language} (unsupported language tag)')
                for attribute in ('eastAsia','bidi'):
                    other=c.get(q(attribute))
                    if other and (not language or other.lower()!=language.lower()):
                        self.rep.add(f'rPr/lang/{attribute}={other} (separate script-language slot not implemented)')
            elif n in self.RPR_SKIP: pass
            else: self.rep.add(f'rPr/{n}')
        if b is not None or i is not None:
            # A direct property replaces only its own inherited bit. The target
            # font-style choice sets both, so carry the other bit explicitly.
            if base_font_flags is not None:
                if b is None:b=base_font_flags['b']
                if i is None:i=base_font_flags['i']
            keys.append('font-style='+('bold-italic' if b and i else 'bold' if b else 'italic' if i else 'regular'))
        if bcs is not None or ics is not None:
            if base_font_flags is not None:
                if bcs is None:bcs=base_font_flags['bCs']
                if ics is None:ics=base_font_flags['iCs']
            keys.append('complex-script-font-style='+('bold-italic' if bcs and ics else 'bold' if bcs else 'italic' if ics else 'regular'))
            if base_font_flags is None and (b is None)!=(i is None): self.rep.add('rPr b/i given alone (the other is set to off)')
        return keys,style

    JC={'left':'left','start':'left','center':'centered','right':'right','end':'right','both':'justified','distribute':'distributed'}
    def ppr(self,e,ctx='paragraph'):
        par=[]; other=[]; style=None
        if e is None: return par,other,style
        for c in e:
            n=c.tag.replace(W,'')
            if n=='pStyle': style=val(c)
            elif n=='jc':
                v=val(c)
                if v in self.JC: par.append(f'alignment={self.JC[v]}')
                else: self.rep.add(f'pPr/jc val={v}')
            elif n=='spacing': par.append('spacing={'+','.join(self.spacing(c))+'}')
            elif n=='ind':
                ik=self.ind(c)
                if ik: par.append('indentation={'+','.join(ik)+'}')
            elif n=='widowControl': par.append(f'pagination={{widow-control={"true" if on(c) else "false"}}}')
            elif n=='keepNext': par.append(f'pagination={{keep-with-next={"true" if on(c) else "false"}}}')
            elif n=='keepLines': par.append(f'pagination={{keep-lines-together={"true" if on(c) else "false"}}}')
            elif n=='pageBreakBefore': par.append(f'pagination={{page-break-before={"true" if on(c) else "false"}}}')
            elif n=='snapToGrid': par.append(f'snap-to-grid-when-document-grid-is-defined={"true" if on(c) else "false"}')
            elif n=='adjustRightInd': par.append(f'indentation={{automatically-adjust-right-indent-when-document-grid-is-defined={"true" if on(c) else "false"}}}')
            elif n=='autoSpaceDE': par.append(f'asian-typography={{automatically-adjust-space-between-asian-and-latin-text={"true" if on(c) else "false"}}}')
            elif n=='autoSpaceDN': par.append(f'asian-typography={{automatically-adjust-space-between-asian-text-and-numbers={"true" if on(c) else "false"}}}')
            elif n=='tabs':
                t=self.tabs(c)
                if t is not None: other.append('tabs={'+t+'}')
            elif n=='pBdr':
                bd=self.border(c)
                if bd: other.append('border={'+bd+'}')
            elif n=='shd':
                f=c.get(q('fill'))
                if f and f!='auto': other.append(f'shading={{fill={f}}}')
            elif n=='wordWrap':
                par.append(f'asian-typography={{allow-latin-text-to-wrap-in-the-middle-of-a-word={"false" if on(c) else "true"}}}')
            elif n=='textAlignment':
                v={'auto':'auto','top':'top','center':'centered','baseline':'baseline','bottom':'bottom'}.get(val(c),'auto')
                par.append(f'asian-typography={{text-alignment={v}}}')
            elif n=='contextualSpacing':
                par.append(f'spacing={{dont-add-space-between-paragraphs-of-the-same-style={"true" if on(c) else "false"}}}')
            elif n=='rPr' or n=='framePr': pass
            elif n=='numPr':
                nid=val(c.find(q('numId'))); lvl=whole(val(c.find(q('ilvl')),default='0') or 0)
                if ctx=='style': self.style_num=(nid,lvl)
                else: self.par_num=(nid,lvl)
            elif n in ('kinsoku','overflowPunct'):
                if not on(c): self.rep.add(f'pPr/{n}=off (docxlike assumes on)')
            elif n in ('cnfStyle','rPrChange','pPrChange'): pass
            elif n=='sectPr': pass
            else: self.rep.add(f'pPr/{n}')
        return par,other,style
    def spacing(self,c):
        k=[]
        for side in ('before','after'):
            lines=c.get(q(side+'Lines'))
            if lines is not None: k.append(f'{side}={{value={whole(lines)/100:g},unit=line}}')
            elif c.get(q(side)) is not None: k.append(f'{side}={bp(c.get(q(side)))}')
            if c.get(q(side+'Autospacing')) in ('1','true','on'): self.rep.add(f'pPr/spacing/{side}Autospacing')
        line=c.get(q('line')); rule=c.get(q('lineRule'),'auto')
        if line is not None:
            if rule=='auto':
                m=whole(line)/240
                if abs(m-1)<1e-9: k.append('line-spacing=single')
                elif abs(m-1.5)<1e-9: k.append('line-spacing=1.5-lines')
                elif abs(m-2)<1e-9: k.append('line-spacing=double')
                else: k.append(f'line-spacing=multiple,at={m:g}')
            elif rule=='exact': k.append(f'line-spacing=exactly,at={bp(line)}')
            elif rule=='atLeast': k.append(f'line-spacing=at-least,at={bp(line)}')
        return k
    def ind(self,c):
        k=[];special=[]
        for side,names in (('left',('left','start')),('right',('right','end'))):
            chars=c.get(q(names[0]+'Chars')) or c.get(q(names[1]+'Chars'))
            tw=c.get(q(names[0])) or c.get(q(names[1]))
            if chars is not None and whole(chars)!=0: k.append(f'{side}={{value={whole(chars)/100:g},unit=ch}}')
            elif tw is not None: k.append(f'{side}={bp(tw)}')
        for kind,attr in (('first-line','firstLine'),('hanging','hanging')):
            chars=c.get(q(attr+'Chars')); tw=c.get(q(attr))
            amount=whole(chars) if chars is not None and whole(chars)!=0 else whole(tw or 0)
            actual_kind=kind if amount>=0 else ('hanging' if kind=='first-line' else 'first-line')
            if chars is not None and whole(chars)!=0: special=[f'special={actual_kind},by={{value={abs(whole(chars))/100:g},unit=ch}}']
            elif tw is not None and whole(tw)!=0: special=[f'special={actual_kind},by={bp(abs(whole(tw)))}']
            elif chars is not None or tw is not None: special=['special=none']
        return k+special
    LEADER={'none':'none','dot':'dot','hyphen':'hyphen','underscore':'underscore','middleDot':'middle-dot'}
    def tabs(self,c):
        out=[]
        for t in c.findall(q('tab')):
            v=val(t)
            if v=='clear': self.rep.add('tab clear (inherited tab not removed)'); continue
            if v in ('decimal','bar','num'): self.rep.add(f'tab alignment={v}'); continue
            al={'left':'left','start':'left','center':'center','right':'right','end':'right'}.get(v)
            if al is None: self.rep.add(f'tab alignment={v}'); continue
            ld=self.LEADER.get(t.get(q('leader'),'none'))
            if ld is None: self.rep.add(f'tab leader={t.get(q("leader"))}'); ld='none'
            out.append('{position='+bp(t.get(q('pos')))+f',alignment={al}'+(f',leader={ld}' if ld!='none' else '')+'}')
        return ','.join(out) if out else None
    def border_side(self,side,extra_space=0):
        v=val(side)
        if v in (None,'nil','none'): return None
        k=['style='+re.sub(r'(?<=[a-z])(?=[A-Z])','-',v).lower()]
        if side.get(q('sz')): k.append(f'width={whole(side.get(q("sz")))/8:g}bp')
        sp=whole(side.get(q('space')) or 0)+extra_space
        if sp: k.append(f'from-text={sp}bp')
        if side.get(q('color')) and side.get(q('color'))!='auto': k.append(f'color={side.get(q("color"))}')
        return '{'+','.join(k)+'}'
    def border(self,c):
        parts=[]
        for side in c:
            n=side.tag.replace(W,'')
            if n not in ('top','bottom'):
                # left and right borders sit outside the text and do not move it; between is handled per group
                if n!='between': self.rep.add(f'pBdr/{n} (not drawn)')
                continue
            v=val(side)
            if v in (None,'nil','none'): continue
            k=['style='+re.sub(r'(?<=[a-z])(?=[A-Z])','-',v).lower()]
            if side.get(q('sz')): k.append(f'width={whole(side.get(q("sz")))/8:g}bp')
            if side.get(q('space')): k.append(f'from-text={side.get(q("space"))}bp')
            if side.get(q('color')) and side.get(q('color'))!='auto': k.append(f'color={side.get(q("color"))}')
            parts.append(n+'={'+','.join(k)+'}')
        return ','.join(parts)

    def style_block(self):
        out=[]
        dd=self.styles.find(q('docDefaults')) if self.styles is not None else None
        present=dd is not None and dd.find(q('pPrDefault')) is not None
        default_ppr=dd.find(f'{q("pPrDefault")}/{q("pPr")}') if present else None
        if not present:
            if self.paragraph_defaults is None:
                self.rep.add('pPrDefault omitted (application-defined paragraph spacing unresolved)')
            else:
                default_ppr=ET.Element(q('pPr'))
                ET.SubElement(default_ppr,q('spacing'),{q(k):str(v) for k,v in self.paragraph_defaults['spacing'].items()})
        p,o,_=self.ppr(default_ppr,'style')
        if dd is not None:
            f,_=self.rpr(dd.find(f'{q("rPrDefault")}/{q("rPr")}'))
            # no w:kern means kerning off in Word, not in docxlike
            if not any(k.startswith('kerning-for-fonts') for k in f): f.append('kerning-for-fonts=false')
            # Word snaps to the grid unless told not to; docxlike does not snap when nothing is set
            if not any(k.startswith('snap-to-grid') for k in f): f.append('snap-to-grid-when-document-grid-is-defined')
            if not any(k.startswith('snap-to-grid') for k in p): p.append('snap-to-grid-when-document-grid-is-defined')
            d=[]
            if f: d.append('font={'+','.join(f)+'}')
            if p: d.append('paragraph={'+','.join(p)+'}')
            d+=o
            if d: out.append('doc-defaults={'+','.join(d)+'}')
        elif not any(x.get(q('type'))=='paragraph' for x in (self.styles.findall(q('style')) if self.styles is not None else [])):
            # no document defaults and no paragraph styles: Word's built-in defaults (ECMA-376 17.7.5)
            extra=(',paragraph={'+','.join(p)+'}') if p else ''
            out.append('doc-defaults={font={latin-text-font=Times New Roman,size=10bp,kerning-for-fonts=false}'+extra+'}')
        elif p:
            out.append('doc-defaults={paragraph={'+','.join(p)+'}}')
        styles=[]
        all_styles=self.styles.findall(q('style')) if self.styles is not None else []
        by_id={x.get(q('styleId')):x for x in all_styles}; ordered=[]; seen=set()
        def visit(x,depth=0):
            sid=x.get(q('styleId'))
            if sid in seen or depth>20: return
            b=x.find(q('basedOn'))
            if b is not None and val(b) in by_id: visit(by_id[val(b)],depth+1)
            seen.add(sid); ordered.append(x)
        for x in all_styles: self.style_names[x.get(q('styleId'))]=(val(x.find(q('name'))) or x.get(q('styleId')))
        for x in all_styles: visit(x)
        for s in ordered:
            t=s.get(q('type')); sid=s.get(q('styleId')); name=(val(s.find(q('name'))) or sid)
            self.style_names[sid]=name
            if sid==self.default_char_style: continue
            if t not in ('paragraph','character'):
                if t=='table' and sid not in ('TableNormal','a1','a2'): self.rep.add('style type=table')
                continue
            self.style_num=None
            f,_=self.rpr(s.find(q('rPr'))); p,o,_=self.ppr(s.find(q('pPr')),'style')
            # The target choice stores both bits: materialize missing inherited
            # bits for both style kinds. The backend retains character-style
            # toggle semantics relative to document defaults.
            flags=self.font_style_flags(sid)
            f=[key for key in f if not key.startswith(('font-style=','complex-script-font-style='))]
            for key,bold,italic in [('font-style','b','i'),('complex-script-font-style','bCs','iCs')]:
                b,i=flags[bold],flags[italic]
                f.append(key+'='+('bold-italic' if b and i else 'bold' if b else 'italic' if i else 'regular'))
            if self.style_num and self.style_num[0] not in (None,'0'): self.style_lists[sid]=self.style_num; self.used_nums.add(self.style_num[0])
            d=[]
            if s.find(q('next')) is not None and val(s.find(q('next'))) in by_id:
                d.append('style-for-following-paragraph='+self.name_of(val(s.find(q('next')))))
            if s.find(q('link')) is not None and val(s.find(q('link'))) in by_id:
                d.append('linked-style='+self.name_of(val(s.find(q('link')))))
            if t=='character': d.append('style-type=character')
            base=s.find(q('basedOn'))
            if base is not None and val(base)!=self.default_char_style:
                if val(base) in by_id: d.append('based-on='+self.name_of(val(base)))
                else: self.rep.add('based-on a style the document does not define (dropped)')
            if f: d.append('font={'+','.join(f)+'}')
            if p: d.append('paragraph={'+','.join(p)+'}')
            d+=o
            styles.append(self.name_of(sid,name)+'={'+','.join(d)+'}')
        if styles: out.append('styles={'+','.join(styles)+'}')
        return out
    def name_of(self,sid,name=None):
        n=name or self.style_names.get(sid,sid)
        return re.sub(r'[{},=]','',n)

    def settings_keys(self):
        k=[]; s=self.settings
        if s is None: return ['character-spacing-control=do-not-compress']
        compat=s.find(q('compat')); mode='15'
        if compat is not None:
            for c in compat:
                n=c.tag.replace(W,'')
                if n=='compatSetting' and c.get(q('name'))=='compatibilityMode': mode=c.get(q('val'))
                elif n=='balanceSingleByteDoubleByteWidth' and on(c): k.append('balance-sbcs-characters-and-dbcs-characters')
                elif n=='doNotUseHTMLParagraphAutoSpacing' and on(c): k.append('dont-use-html-paragraph-auto-spacing')
                elif n=='useAnsiKerningPairs' and on(c): k.append('use-ansi-kerning-pairs')
                elif n=='useAltKinsokuLineBreakRules' and on(c): k.append('use-alt-kinsoku-line-break-rules=true')
                elif n=='noColumnBalance' and on(c): k.append('no-column-balance')
                elif n in ('useFELayout','compatSetting'): pass
                elif n in self.COMPAT_KEYS:
                    k.append(self.COMPAT_KEYS[n]+('' if on(c) else '=false'))
                    if n=='doNotExpandShiftReturn': self.no_expand_shift_return=bool(on(c))
                else: self.rep.add(f'compat/{n}')
        else: mode='11'
        self.compat=int(mode) if mode.isdigit() else 15
        k.insert(0,'compatibility-mode='+{'11':'word-2003','12':'word-2007','14':'word-2010','15':'word-2013'}.get(mode,'word-2013'))
        csc=s.find(q('characterSpacingControl'))
        # ISO/IEC 29500: an omitted characterSpacingControl means no compression.
        # Emit it explicitly instead of inheriting the target package's author default.
        csc_value=val(csc) if csc is not None else 'doNotCompress'
        csc_key={'doNotCompress':'do-not-compress','compressPunctuation':'compress-punctuation'}.get(csc_value)
        if csc_key is None:
            self.rep.add(f'characterSpacingControl={csc_value} (do-not-compress fallback)')
            csc_key='do-not-compress'
        k.append('character-spacing-control='+csc_key)
        dts=s.find(q('defaultTabStop'))
        if dts is not None: k.append(f'default-tab-stops={bp(val(dts))}')
        ah=s.find(q('autoHyphenation'))
        k.append('hyphenation='+('automatic' if on(ah) else 'none'))
        if s.find(q('evenAndOddHeaders')) is not None and on(s.find(q('evenAndOddHeaders'))): self.even_odd=True
        return k
    COMPAT_KEYS={'adjustLineHeightInTable':'adjust-line-height-to-grid-height-in-the-table','spaceForUL':'add-space-for-underline','ulTrailSpace':'underline-trailing-spaces','doNotExpandShiftReturn':'dont-expand-character-spaces-on-a-line-ending-with-shift-return','doNotLeaveBackslashAlone':'convert-backslash-characters-into-yen-signs','doNotUseEastAsianBreakRules':'dont-use-east-asian-line-break-rules','doNotWrapTextWithPunct':'dont-wrap-text-with-punctuation','doNotUseIndentAsNumberingTabStop':'dont-use-hanging-indent-as-tab-stop-for-bullets-and-numbering','splitPgBreakAndParaMark':'split-page-break-and-paragraph-mark','useNormalStyleForList':'use-normal-style-for-bulleted-and-numbered-lists','doNotBreakConstrainedForcedTable':'dont-break-constrained-tables-forced-onto-the-page','doNotVertAlignInTxbx':'dont-vertically-align-text-in-text-boxes','displayHangulFixedWidth':'display-hangul-with-fixed-width','doNotSuppressIndentation':'dont-suppress-indentation-around-floating-objects','doNotAutofitConstrainedTables':'dont-autofit-constrained-tables','autofitToFirstFixedWidthCell':'autofit-to-the-first-fixed-width-cell','allowSpaceOfSameStyleInTable':'allow-space-between-paragraphs-of-the-same-style-in-a-table','doNotVertAlignCellWithSp':'dont-vertically-align-table-cells-containing-shapes','cachedColBalance':'cached-column-balance','doNotBreakWrappedTables':'dont-allow-floating-tables-to-break-across-pages','selectFldWithFirstOrLastChar':'select-entire-field-with-first-or-last-character','growAutofit':'allow-tables-to-extend-into-margins','useWord2002TableStyleRules':'use-word-2002-table-style-rules','doNotSnapToGridInCell':'dont-snap-text-to-grid-inside-table-with-inline-objects','footnoteLayoutLikeWW8':'lay-out-footnotes-like-word-6-x-95-97','useWord97LineBreakRules':'use-word-97-line-breaking-rules-for-asian-text','shapeLayoutLikeWW8':'lay-out-autoshapes-like-word-97','forgetLastTabAlignment':'ignore-the-last-tabs-alignment','layoutRawTableWidth':'dont-add-table-padding-to-width','layoutTableRowsApart':'dont-allow-table-rows-to-lay-out-apart','alignTablesRowByRow':'align-table-rows-independently'}
    GRID={'default':'no-grid','lines':'specify-line-grid-only','linesAndChars':'specify-line-and-character-grid','snapToChars':'text-snaps-to-character-grid'}
    PAGE_BREAK=r'\vadjust{\penalty-10000}\newline '
    SECTION_TYPE={'nextPage':'next-page','continuous':'continuous','evenPage':'even-page','oddPage':'odd-page'}
    def sections(self):
        # a section ends at a paragraph carrying w:sectPr; the body's own w:sectPr is the last one
        body=self.doc.find(q('body'))
        out=[x for x in body.iter(q('sectPr')) if x is not body.find(q('sectPr'))]
        if body.find(q('sectPr')) is not None: out.append(body.find(q('sectPr')))
        return out
    def section_break(self,sect):
        t=val(sect.find(q('type')),default='nextPage')
        if t not in self.SECTION_TYPE: self.rep.add(f'sectPr/type={t} (next page used)')
        keys=self.page_keys(self.normal_size(),sect,section=True)
        return ['\\docxinsert[section-break='+self.SECTION_TYPE.get(t,'next-page')+']{'+','.join(keys)+'}']+self.headers_footers(sect)
    def page_keys(self,normal_size,sect=None,section=False):
        if sect is None: sect=self.section_list[0] if self.section_list else None
        if sect is None: return []
        paper=[]; margins=[]; layout=[]; grid=[]
        sz=sect.find(q('pgSz'))
        if sz is not None:
            paper=[f'width={bp(sz.get(q("w")))}',f'height={bp(sz.get(q("h")))}']
        m=sect.find(q('pgMar'))
        if m is not None:
            for side in ('top','bottom','left','right','gutter'):
                if m.get(q(side)) is not None: margins.append(f'{side}={bp(m.get(q(side)))}')
            fe=[f'{x}={bp(m.get(q(x)))}' for x in ('header','footer') if m.get(q(x)) is not None]
            if fe: layout.append('from-edge={'+','.join(fe)+'}')
        if sect.find(q('titlePg')) is not None and on(sect.find(q('titlePg'))): layout.append('different-first-page')
        if getattr(self,'even_odd',False) and not section: layout.append('different-odd-and-even')
        g=sect.find(q('docGrid'))
        if g is not None:
            t=self.GRID.get(g.get(q('type'),'default'),'no-grid'); grid.append(f'grid={t}')
            if g.get(q('linePitch')): grid.append(f'lines={{pitch={bp(g.get(q("linePitch")))}}}')
            if t in ('specify-line-and-character-grid','text-snaps-to-character-grid') and g.get(q('charSpace')):
                grid.append(f'characters={{pitch={normal_size+whole(g.get(q("charSpace")))/4096:g}bp}}')
        else: grid.append('grid=no-grid')
        extra=[]
        cols=sect.find(q('cols'))
        if cols is not None and whole(cols.get(q('num'),'1'))>1:
            ck=[f'number-of-columns={whole(cols.get(q("num")))}']
            if cols.get(q('space')): ck.append(f'spacing={bp(cols.get(q("space")))}')
            if on(cols.find(q('sep'))) or cols.get(q('sep')) in ('1','true','on'): ck.append('line-between')
            if cols.get(q('equalWidth')) in ('0','false','off'): self.rep.add('sectPr/cols unequal widths (set equal)')
            extra.append('columns={'+','.join(ck)+'}')
        elif section: extra.append('columns={number-of-columns=1}')
        for n in ('pgBorders','lnNumType','vAlign','textDirection','rtlGutter'):
            if sect.find(q(n)) is not None: self.rep.add(f'sectPr/{n}')
        pn=sect.find(q('pgNumType'))
        if pn is not None:
            pk=[]
            if pn.get(q('fmt')): pk.append('number-format='+re.sub(r'(?<=[a-z0-9])(?=[A-Z])','-',pn.get(q('fmt'))).lower())
            if pn.get(q('start')) is not None: pk.append(f'start-at={whole(pn.get(q("start")))}')
            for a in ('chapStyle','chapSep'):
                if pn.get(q(a)): self.rep.add(f'sectPr/pgNumType {a}')
            if pk: extra.append('page-number-format={'+','.join(pk)+'}')
        ps=[]
        if paper: ps.append('paper={'+','.join(paper)+'}')
        if margins: ps.append('margins={'+','.join(margins)+'}')
        if layout: ps.append('layout={'+','.join(layout)+'}')
        if grid: ps.append('document-grid={'+','.join(grid)+'}')
        return (['page-setup={'+','.join(ps)+'}'] if ps else [])+extra
    def note(self,kind,nid):
        part=self.notes_xml.setdefault(kind,self.xml(f'word/{kind}s.xml'))
        node=None
        if part is not None:
            node=next((x for x in part.findall(q(kind)) if x.get(q('id'))==nid),None)
        if node is None: self.rep.add(f'{kind} without text'); return ''
        self.used_notes.add(kind)
        mark=any(True for _ in node.iter(q(kind+'Ref')))
        # Only a present note-body marker is replaced by the runtime's prefix.
        # Missing footnoteRef/endnoteRef must not invent a visible mark or space.
        if mark:
            for t in node.iter(q('t')):
                t.text=(t.text or '').lstrip()
                if t.text: break
        saved=self.fields; self.fields=[]; story=self.story; self.story='note'
        pars=[self.paragraph_runs(x) for x in node.findall(q('p'))]
        self.story=story
        self.fields=saved
        body='\\par '.join(x for x in pars if x.strip())
        if mark: return '\\docxinsert['+kind+']{'+body+'}'
        return r'\csname __docxlike_note_import:nnnn\endcsname{'+kind+'}{}{false}{'+body+'}'
    NOTE_RESTART={'continuous':'continuous','eachSect':'restart-each-section','eachPage':'restart-each-page'}
    NOTE_POS={'pageBottom':'bottom-of-page','beneathText':'below-text','docEnd':'end-of-document','sectEnd':'end-of-section'}
    def note_keys(self):
        out=[]
        for kind in ('footnote','endnote'):
            if kind not in self.used_notes: continue
            k=[]
            sect=self.doc.find(f'{q("body")}/{q("sectPr")}')
            for src in (self.settings, sect):
                pr=src.find(q(kind+'Pr')) if src is not None else None
                if pr is None: continue
                f=pr.find(q('numFmt'))
                if f is not None: k=[x for x in k if not x.startswith('number-format=')]+['number-format='+re.sub(r'(?<=[a-z0-9])(?=[A-Z])','-',val(f)).lower()]
                st=pr.find(q('numStart'))
                if st is not None: k=[x for x in k if not x.startswith('start-at=')]+[f'start-at={val(st)}']
                rs=pr.find(q('numRestart'))
                if rs is not None and val(rs) in self.NOTE_RESTART: k=[x for x in k if not x.startswith('numbering=')]+['numbering='+self.NOTE_RESTART[val(rs)]]
                ps=pr.find(q('pos'))
                if ps is not None and val(ps) in self.NOTE_POS: k=[x for x in k if not x.startswith('location=')]+['location='+self.NOTE_POS[val(ps)]]
            if not any(x.startswith('number-format=') for x in k): k.append('number-format='+('decimal' if kind=='footnote' else 'lower-roman'))
            if kind=='footnote': k+=self.note_stories()
            out.append(kind+'s={'+','.join(k)+'}')
        return out
    NOTE_STORIES={'separator':('separator','separator'),'continuationSeparator':('continuation-separator','continuationSeparator'),
                  'continuationNotice':('continuation-notice',None)}
    def note_stories(self):
        # the separator, continuation separator and continuation notice: one paragraph each in footnotes.xml
        part=self.notes_xml.setdefault('footnote',self.xml('word/footnotes.xml'))
        out=[]
        if part is None: return out
        # Word keeps no room for a continuation notice the document does not have
        if not any(n.get(q('type'))=='continuationNotice' for n in part.findall(q('footnote'))): out.append('continuation-notice=none')
        for node in part.findall(q('footnote')):
            kind=node.get(q('type'))
            if kind not in self.NOTE_STORIES: continue
            key,mark_tag=self.NOTE_STORIES[kind]
            ps=node.findall(q('p'))
            if not ps: continue
            if len(ps)>1: self.rep.add(f'footnote {kind} with more than one paragraph (first kept)')
            p=ps[0]
            par,other,style=self.ppr(p.find(q('pPr')))
            mark=mark_tag is not None and any(r.find(q(mark_tag)) is not None for r in p.findall(q('r')))
            saved=self.story; self.story='note'; text=self.paragraph_runs(p).strip(); self.story=saved
            font=[]
            for r in p.findall(q('r')):
                if mark_tag is not None and r.find(q(mark_tag)) is not None:
                    font,_=self.rpr(r.find(q('rPr'))); break
            if not font and not text:
                font,_=self.rpr(p.find(f'{q("pPr")}/{q("rPr")}'))
            keys=[]
            if style: keys.append(f'style={self.name_of(style)}')
            if par: keys.append('paragraph={'+','.join(par)+'}')
            keys+=[x for x in other if x.split('=')[0] in ('border','shading')]
            if font: keys.append('font={'+','.join(font)+'}')
            if mark_tag is not None and not mark: keys.append('mark=false')
            if text: keys.append('text={'+text+'}')
            if keys: out.append(key+'={'+','.join(keys)+'}')
        return out
    @staticmethod
    def list_name(nid): return f'L{nid}'
    BULLETS={'\uf0b7':'•','\uf0a7':'▪','\uf0d8':'➢','\uf076':'❖','\uf0fc':'✓','\uf06e':'■','\uf0a8':'◆'}
    def numbering_defs(self):
        if self.numbering is None or not self.used_nums: return []
        absn={a.get(q('abstractNumId')):a for a in self.numbering.findall(q('abstractNum'))}
        nums={n.get(q('numId')):n for n in self.numbering.findall(q('num'))}
        links={nid:(sid,lvl) for sid,(nid,lvl) in self.style_lists.items()}
        out=[]
        for nid in sorted(self.used_nums,key=lambda x:whole(x)):
            num=nums.get(nid)
            if num is None: self.rep.add('numId without a definition'); continue
            if num.find(q('lvlOverride')) is not None: self.rep.add('numbering lvlOverride (not converted yet)')
            a=absn.get(val(num.find(q('abstractNumId'))))
            if a is None: continue
            if a.find(q('numStyleLink')) is not None or a.find(q('styleLink')) is not None: self.rep.add('numbering list style link (not converted yet)')
            keys=[f'listnum-field-list-name={self.list_name(nid)}']
            for lv in a.findall(q('lvl')):
                il=whole(lv.get(q('ilvl'),'0')); keys.append(f'click-level-to-modify={il+1}')
                nf=[]; pos=[]
                fmt=val(lv.find(q('numFmt')),default='decimal')
                text=val(lv.find(q('lvlText')),default='')
                if fmt=='bullet':
                    t2=''.join(self.BULLETS.get(ch,ch) for ch in text)
                    if any('\ue000'<=ch<='\uf8ff' for ch in t2): self.rep.add('bullet with a symbol-font character'); t2='•'
                    text=t2
                nf.append('enter-formatting-for-number={'+self.text(text).replace('\\ ',' ')+'}')
                nf.append('number-style-for-this-level='+re.sub(r'(?<=[a-z0-9])(?=[A-Z])','-',fmt).lower())
                st=lv.find(q('start'))
                if st is not None and val(st)!='1': nf.append(f'start-at={val(st)}')
                rs=lv.find(q('lvlRestart'))
                if rs is not None: nf.append('restart-list-after='+('none' if val(rs)=='0' else f'level-{val(rs)}'))
                if lv.find(q('isLgl')) is not None and on(lv.find(q('isLgl'))): nf.append('legal-style-numbering')
                fk,_=self.rpr(lv.find(q('rPr')))
                if fmt=='bullet':
                    # the bullet is now a Unicode character, which a symbol font does not have
                    fk=[k for k in fk if not (k.split('=')[0].endswith('-font') and k.split('=',1)[1] in self.SYMBOL_FONTS)]
                if fk: nf.append('font={'+','.join(fk)+'}')
                jc=val(lv.find(q('lvlJc')))
                if jc: pos.append('number-alignment='+{'left':'left','start':'left','center':'centered','right':'right','end':'right'}.get(jc,'left'))
                ind=lv.find(f'{q("pPr")}/{q("ind")}')
                if ind is not None:
                    left=whole(ind.get(q('left')) or ind.get(q('start')) or 0)
                    first=whole(ind.get(q('firstLine')) or 0)-whole(ind.get(q('hanging')) or 0)
                    pos+= [f'aligned-at={bp(left+first)}',f'text-indent-at={bp(left)}']
                suff=val(lv.find(q('suff')),default='tab')
                pos.append('follow-number-with='+{'tab':'tab-character','space':'space','nothing':'nothing'}.get(suff,'tab-character'))
                tab=lv.find(f'{q("pPr")}/{q("tabs")}/{q("tab")}')
                if tab is not None and suff=='tab' and val(tab)=='num': pos.append(f'add-tab-stop-at={bp(tab.get(q("pos")))}')
                keys.append('number-format={'+','.join(nf)+'}'); keys.append('position={'+','.join(pos)+'}')
                for sid,(lnid,llvl) in self.style_lists.items():
                    if lnid==nid and llvl==il: keys.append('link-level-to-style='+self.name_of(sid))
            out.append('\\docxformat[define-new-multilevel-list={'+','.join(keys)+'}]{}')
        return out
    HF_TYPE={'default':'','first':'first-page','even':'even-page'}
    def headers_footers(self,sect=None):
        if sect is None: sect=self.section_list[0] if self.section_list else None
        if sect is None: return []
        out=[]
        for tag,cmd in (('headerReference','header'),('footerReference','footer')):
            for ref in sect.findall(q(tag)):
                target=self.rels.get(ref.get(R+'id'))
                part=self.xml('word/'+target) if target else None
                if part is None: continue
                # images in a header or footer are named in that part's own relationships
                self.part_rels=self.load_rels(Path(target).name)
                pars=[]
                for e in part:
                    n=e.tag.replace(W,'')
                    if n=='p': pars+=self.paragraph(e,story='headfoot')
                    elif n=='sdt':
                        c=e.find(q('sdtContent'))
                        for x in (c.findall(q('p')) if c is not None else []): pars+=self.paragraph(x,story='headfoot')
                    elif n=='tbl': pars.append(self.table(e))
                    else: self.rep.add(f'{tag}/{n}')
                self.part_rels=None
                out.append('\\docxinsert['+cmd+'={'+self.HF_TYPE.get(ref.get(q('type'),'default'),'')+'}]{'+'\n'.join(pars)+'}')
                self.any_headfoot=True
        return out
    def normal_size(self):
        for s in (self.styles.findall(q('style')) if self.styles is not None else []):
            if s.get(q('type'))=='paragraph' and s.get(q('default')) in ('1','true'):
                e=s.find(f'{q("rPr")}/{q("sz")}')
                if e is not None: return whole(val(e))/2
        e=self.styles.find(f'{q("docDefaults")}/{q("rPrDefault")}/{q("rPr")}/{q("sz")}') if self.styles is not None else None
        return whole(val(e))/2 if e is not None else 10.0

    SPECIAL={'\\':r'\textbackslash{}','{':r'\{','}':r'\}','$':r'\$','&':r'\&','#':r'\#','^':r'\^{}','_':r'\_','%':r'\%','~':r'\textasciitilde{}'}
    SYMBOL_FONTS={'Symbol','Wingdings','Wingdings 2','Wingdings 3','Webdings','MT Extra','Marlett'}
    def text(self,s):
        out=[]; prev_space=True
        for ch in s:
            if ch==' ':
                out.append('\\ ' if prev_space else ' '); prev_space=True
            else:
                out.append(self.SPECIAL.get(ch,ch)); prev_space=False
        return ''.join(out)
    @staticmethod
    def link(anchor,url,inner):
        # docxlike only finds tabs outside braces, so split the link at them
        head=r'\docxinsert[hyperlink={address={'+url+'},bookmark={'+(anchor or '')+'}}]'
        return Converter.TAB.join(head+'{'+x+'}' if x else '' for x in inner.split(Converter.TAB))
    @staticmethod
    def split_top(text,sep):
        # split at sep where it is outside braces
        out,depth,start,i=[],0,0,0
        while i<len(text):
            c=text[i]
            if c=='\\' and i+1<len(text) and text[i+1] in '{}': i+=2; continue
            if c=='{': depth+=1
            elif c=='}': depth-=1
            elif depth==0 and text.startswith(sep,i): out.append(text[start:i]); i+=len(sep); start=i; continue
            i+=1
        out.append(text[start:]); return out
    @staticmethod
    def bookmarked_note(inner,name):
        # a bookmark around just a note reference is what NOTEREF points at (Word's cross-reference to a note)
        for kind in ('footnote','endnote'):
            variants=[(r'\docxinsert['+kind+']{',r'\docxinsert['+kind+'={bookmark='+name+'}]'),
                      (r'\csname __docxlike_note_import:nnnn\endcsname{'+kind+'}{}{false}{',
                       r'\csname __docxlike_note_import:nnnn\endcsname{'+kind+'}{bookmark='+name+'}{false}')]
            for cmd,prefix in variants:
                if not inner.startswith(cmd): continue
                depth,escaped=0,False
                for i,c in enumerate(inner[len(cmd)-1:],len(cmd)-1):
                    if escaped: escaped=False; continue
                    if c=='\\': escaped=True; continue
                    depth+=c=='{'; depth-=c=='}'
                    if depth==0: return prefix+inner[len(cmd)-1:] if i==len(inner)-1 else None
        return None
    @staticmethod
    def bookmarks(out):
        # a bookmark that starts and ends in this paragraph wraps its text; one that does not, or that
        # would cross a tab or another bookmark, is an empty bookmark at its start
        res=[]; stack=[]
        for x in out:
            if isinstance(x,tuple) and x[0]=='bm':
                stack.append((x[1],x[2],len(res))); res.append(None)
            elif isinstance(x,tuple) and x[0]=='be':
                k=next((i for i in range(len(stack)-1,-1,-1) if stack[i][0]==x[1]),None)
                if k is None: continue
                bid,name,at=stack.pop(k)
                inner=''.join(y for y in res[at+1:] if isinstance(y,str))
                nested=k==len(stack) and all(isinstance(y,str) for y in res[at+1:])
                note=Converter.bookmarked_note(inner,name) if nested else None
                if note: res[at:]=[note]
                elif nested and Converter.TAB not in inner and inner:
                    res[at:]=[r'\docxinsert[bookmark={'+name+'}]{'+inner+'}']
                else: res[at]=r'\docxinsert[bookmark={'+name+'}]{}'
            else: res.append(x)
        for bid,name,at in stack: res[at]=r'\docxinsert[bookmark={'+name+'}]{}'
        return [y for y in res if y is not None]
    def runs(self,parent):
        out=[]
        for e in parent:
            n=e.tag.replace(W,'')
            if n=='r': out.append(self.run(e))
            elif n=='hyperlink':
                inner=self.runs(e)
                if not inner and self.fields: continue
                rid=e.get(R+'id'); anchor=e.get(q('anchor'))
                target=self.rels.get(rid) if rid else None
                self.uses_links=True
                url=lambda t:t.replace('%',r'\%').replace('#',r'\#')
                if target: out.append(self.link(anchor,url(target),inner))
                elif anchor: out.append(self.link(anchor,'',inner))
                else: out.append(inner)
            elif n=='fldSimple':
                instr=re.sub(r'\s*\\\*\s*(MERGEFORMAT|CHARFORMAT)\b','',e.get(q('instr')),flags=re.I).strip()
                out.append(r'\docxinsert[field]{'+self.field_instruction(instr)+'}')
            elif n=='bookmarkStart':
                name=e.get(q('name'))
                if name and name!='_GoBack': out.append(('bm',e.get(q('id')),name))
            elif n=='bookmarkEnd': out.append(('be',e.get(q('id'))))
            elif n in ('proofErr','permStart','permEnd','commentRangeStart','commentRangeEnd'): pass
            elif n in ('ins','smartTag','customXml'): out.append(self.runs(e))
            elif n=='sdt':
                c=e.find(q('sdtContent'))
                if c is not None: out.append(self.runs(c)); self.rep.add('sdt (content kept, control dropped)')
            elif n=='del': self.rep.add('tracked deletion (dropped)')
            elif n=='pPr': pass
            elif e.tag==M+'oMath':
                self.uses_math=True
                out.append('$'+Math(self.rep).seq(e)+'$')
            elif e.tag==M+'oMathPara':
                # each equation of a display paragraph on its own line, centred by default as in Word
                self.uses_math=True; self.display_math=True
                jc=mval(e.find(M+'oMathParaPr'),'jc','centerGroup')
                if jc not in ('center','centerGroup'): self.rep.add(f'display math justification {jc} (centred)')
                out.append(r'\break '.join('$\\displaystyle '+Math(self.rep).seq(x)+'$' for x in e.findall(M+'oMath')))
            else: self.rep.add(f'p/{n}')
        return ''.join(self.bookmarks(out))
    FIELD_TYPES={'PAGE','NUMPAGES','SECTIONPAGES','SECTION','TOC','PAGEREF','REF','STYLEREF','SEQ','LISTNUM','NOTEREF',
                 'HYPERLINK','DOCVARIABLE','DOCPROPERTY','DATE','TIME','AUTHOR','TITLE','FILENAME','='}
    def cached_field(self):
        return bool(self.fields and self.fields[0].get('cached'))
    def field_instruction(self,instr):
        """Keep a named LISTNUM field bound to the same imported numId."""
        match=re.match(r'^LISTNUM\s+',instr,re.I)
        if match is None or self.numbering is None: return instr
        pending=False;argument=None
        for token in re.finditer(r'"[^"]*"|\\.|[^\s\\"]+',instr[match.end():]):
            value=token[0]
            if value.startswith('\\'):
                pending=True
            elif pending:
                pending=False
            else:
                argument=token;break
        if argument is None:return instr
        name=argument[0].strip('"').casefold()
        abstracts={a.get(q('abstractNumId')):a for a in self.numbering.findall(q('abstractNum'))}
        matches=[]
        for num in self.numbering.findall(q('num')):
            abstract=abstracts.get(val(num.find(q('abstractNumId'))))
            original=val(abstract.find(q('name'))) if abstract is not None else None
            if original and original.casefold()==name: matches.append(num.get(q('numId')))
        if len(matches)==1:
            self.used_nums.add(matches[0])
            replacement=self.list_name(matches[0])
            start,end=match.end()+argument.start(),match.end()+argument.end()
            return instr[:start]+replacement+instr[end:]
        if len(matches)>1:
            self.rep.add('LISTNUM named list has multiple numId instances (association unresolved)')
        elif name not in ('numberdefault','outlinedefault','legaldefault'):
            # Undefined Word names fall back to NumberDefault; keep them from
            # accidentally binding to the importer's generated L<numId> names.
            start,end=match.end()+argument.start(),match.end()+argument.end()
            return instr[:start]+'NumberDefault'+instr[end:]
        return instr
    def field_out(self,f):
        # \* MERGEFORMAT and \* CHARFORMAT only tell Word how to keep formatting on update
        instr=self.field_instruction(re.sub(r'\s*\\\*\s*(MERGEFORMAT|CHARFORMAT)\b','',f['instr'],flags=re.I).strip())
        kind=(instr.split() or [''])[0].upper()
        if kind=='TOC':
            keep=[]
            for sw in re.findall(r'\\(\w)\s*("[^"]*")?',instr):
                if sw[0].lower()=='f' and not sw[1]: self.rep.add('TOC switch \\f without an identifier (dropped)')
                elif sw[0].lower() in 'ohtfc': keep.append('\\'+sw[0].lower()+(' '+sw[1] if sw[1] else ''))
                else: self.rep.add(f'TOC switch \\{sw[0]} (dropped)')
            if '\\h' in keep: self.uses_links=True
            self.blocks.append(r'\docxinsert[field]{'+' '.join(['TOC']+keep)+'}')
            return []
        if kind=='HYPERLINK':
            m=re.match(r'HYPERLINK\s+(?:"([^"]*)"|([^\s\\]+))?\s*(?:\\l\s+"([^"]*)")?',instr,re.I)
            url=(m.group(1) or m.group(2) or '') if m else ''; anchor=m.group(3) if m else None
            if not url and not anchor: return f['result']
            self.uses_links=True
            inner=''.join(self.TAB if x is None else x for x in f['result'])
            esc=url.replace('%',r'\%').replace('#',r'\#')
            return [self.link(anchor,esc,inner)]
        if kind=='=' and not instr[1:].strip() or kind.startswith('=') and not instr.lstrip('= ').strip():
            self.rep.add('field = without an expression (cached result kept as text)'); return f['result']
        pic=re.search(r'\\#\s*"([^"]*)"',instr)
        if pic and re.search(r'[^0#.,\s%x+-]',pic.group(1).replace("'",'')):
            self.rep.add('field number picture with literal text (cached result kept as text)'); return f['result']
        if kind in self.FIELD_TYPES:
            if kind in ('HYPERLINK','PAGEREF','REF','NOTEREF') or ' \\h' in instr: self.uses_links=True
            return [r'\docxinsert[field]{'+instr+'}']
        self.rep.add(f'field {kind or "(empty)"} (cached result kept as text)')
        return f['result']
    def run(self,r):
        properties=r.find(q('rPr'))
        character_style=val(properties.find(q('rStyle'))) if properties is not None else None
        inherited=self.font_style_flags(character_style or self.default_char_style,base=self.paragraph_font_flags,character=True)
        keys,style=self.rpr(properties,base_font_flags=inherited)
        if style:
            # Retain the character-style reference for its other properties, but
            # project its paragraph-dependent b/i result as an absolute run choice.
            effective=dict(inherited)
            for name in ('b','i'):
                element=properties.find(q(name)) if properties is not None else None
                if element is not None:effective[name]=on(element)
            b,i=effective['b'],effective['i']
            keys=[key for key in keys if not key.startswith('font-style=')]
            keys.append('font-style='+('bold-italic' if b and i else 'bold' if b else 'italic' if i else 'regular'))
        parts=[]
        # symbol fonts index their glyphs at U+F020-U+F0FF; Word shows a typed character in them as that glyph
        fonts=r.find(f'{q("rPr")}/{q("rFonts")}')
        symbolic=fonts is not None and (fonts.get(q('ascii')) or '') in self.SYMBOL_FONTS
        def run_text(t):
            if symbolic: t=''.join(chr(0xF000+ord(ch)) if 0x20<ord(ch)<0x100 else ch for ch in t)
            return self.text(t)
        for c in r:
            n=c.tag.replace(W,'')
            if n=='rPr': continue
            if n=='fldChar':
                t=c.get(q('fldCharType'))
                if t=='begin': self.fields.append({'instr':'','state':'instr','result':[],'cached':False})
                elif t=='separate' and self.fields:
                    field=self.fields[-1]; field['state']='result'
                    field['cached']=(field['instr'].split() or [''])[0].upper() not in self.FIELD_TYPES
                elif t=='end' and self.fields:
                    f=self.fields.pop()
                    if not self.fields: parts.extend(self.field_out(f))
                continue
            # Emit unknown caches in place, including nested results but not instructions.
            if self.fields and not (self.cached_field() and all(f['state']=='result' for f in self.fields)):
                top=self.fields[0]
                if len(self.fields)==1 and top['state']=='instr' and n=='instrText': top['instr']+=c.text or ''
                elif len(self.fields)==1 and top['state']=='result':
                    if n=='t': top['result'].append(run_text(c.text or ''))
                    elif n=='tab': top['result'].append(None)
                continue
            if n=='t': parts.append(run_text(c.text or ''))
            elif n=='tab': parts.append(None)
            elif n=='br':
                t=c.get(q('type'))
                # Word justifies a line ended by Shift+Enter unless doNotExpandShiftReturn; \newline adds \hfil
                if t in (None,'textWrapping'): parts.append(r'\newline ' if self.no_expand_shift_return else r'\break ')
                # a page break ends the line and the page; the paragraph goes on at the top of the next page
                # the line before it is justified in Word 2003-2010 layout, not in 2013
                elif t=='page': parts.append(self.PAGE_BREAK if self.compat>=15 else self.PAGE_BREAK.replace(r'\newline ',r'\break '))
                else: self.rep.add(f'br type={t}')
            elif n=='cr': parts.append(r'\newline ' if self.no_expand_shift_return else r'\break ')
            elif n=='sym':
                font,code=c.get(q('font')) or '',c.get(q('char')) or ''
                # w:char of a symbol font may omit the F0 high byte; its glyphs sit at U+F020-U+F0FF
                if font in self.SYMBOL_FONTS and re.fullmatch(r'[0-9A-Fa-f]{1,4}',code) and int(code,16)<0x100: code=f'F0{int(code,16):02X}'
                parts.append(r'\docxinsert[symbol={font='+font+',character-code='+code+'}]{}')
            # amsmath's \nobreakdash is not robust and breaks inside bookmark text; a boxed hyphen does not break
            elif n=='noBreakHyphen': parts.append('\\mbox{-}')
            elif n=='softHyphen': parts.append('\\-')
            elif n in ('lastRenderedPageBreak','footnoteRef','endnoteRef','separator','continuationSeparator'): pass
            elif n in ('footnoteReference','endnoteReference'):
                parts.append(self.note(n[:-9],c.get(q('id'))))
            elif n=='drawing':
                pic=self.drawing(c)
                if pic: parts.append(('raw',pic))
                elif pic is None: self.rep.add('drawing (not converted)')
            elif n=='pict':
                pic=self.vml_picture(c)
                if pic: parts.append(('raw',pic))
                else: self.rep.add('pict (VML shape, not converted)')
            elif n=='object':
                pic=self.vml_picture(c)
                if pic: parts.append(('raw',pic)); self.rep.add('object (OLE: its preview picture used)')
                else: self.rep.add('object (OLE, not converted)')
            elif c.tag==MC+'AlternateContent':
                # Word writes a fallback for older readers; the choice is usually a drawing
                ch=c.find(MC+'Choice'); fb=c.find(MC+'Fallback')
                done=False
                for alt in (ch,fb):
                    if alt is None or done: continue
                    for x in alt:
                        xn=x.tag.replace(W,'')
                        pic=self.drawing(x) if xn=='drawing' else self.vml_picture(x) if xn=='pict' else None
                        if pic is not None:
                            if pic: parts.append(('raw',pic))
                            done=True; break
                if not done: self.rep.add('AlternateContent (not converted)')
            else: self.rep.add(f'r/{n}')
        # Note insertion sets the reference mark in its own reference style; the run's copy
        # of that style would make the mark a superscript of a superscript
        if style and any(c.tag in (q('footnoteReference'),q('endnoteReference')) for c in r) \
                and self.name_of(style).lower().replace(' ','') in ('footnotereference','endnotereference'):
            style=None
        raw_font=self.font_requires_backend(keys)
        if raw_font:self.rep.add('run font outside supported author controls (programming route)')
        opts=(([f'style={self.name_of(style)}'] if style else [])+keys if raw_font else
              self.font_options(keys, self.name_of(style) if style else None))
        out=[]; chunk=[]
        def flush():
            body=''.join(chunk); chunk.clear()
            if not body: return
            if not opts: out.append(body); return
            # docxlike finds tabs only outside braces: a tab that came in with a hyperlink splits the run
            for i,piece in enumerate(Converter.split_top(body,self.TAB)):
                if i: out.append(self.TAB)
                if piece:
                    out.append((r'\csname docxlike_run:nn\endcsname{'+','.join(opts)+'}{'+piece+'}') if raw_font else
                               (r'\docxformat['+','.join(opts)+']{'+piece+'}'))
        for x in parts:
            if x is None: flush(); out.append(self.TAB)
            elif isinstance(x,tuple): flush(); out.append(x[1])
            else: chunk.append(x)
        flush()
        return ''.join(out)
    def paragraph_runs(self,p):
        previous=self.paragraph_font_flags
        style=val(p.find(f'{q("pPr")}/{q("pStyle")}')) or self.default_par_style
        self.paragraph_font_flags=self.font_style_flags(style)
        try:return self.runs(p)
        finally:self.paragraph_font_flags=previous
    def paragraph(self,p,story='body'):
        # Only known fields replace their cached paragraphs.
        open_before=bool(self.fields)
        cached_before=self.cached_field()
        previous=self.paragraph_font_flags
        style=val(p.find(f'{q("pPr")}/{q("pStyle")}')) or self.default_par_style
        self.paragraph_font_flags=self.font_style_flags(style)
        try:out=self.paragraph1(p,story)
        finally:self.paragraph_font_flags=previous
        if not (cached_before or self.cached_field()):
            if open_before and self.fields: out=None
            elif (open_before or self.fields) and not self.last_content.strip(): out=None
        res=self.anchors+([out] if out is not None else [])+self.blocks; self.blocks=[]; self.anchors=[]
        sp=p.find(f'{q("pPr")}/{q("sectPr")}')
        if sp is not None and story=='body':
            i=next((k for k,x in enumerate(self.section_list) if x is sp),None)
            if i is not None and i+1<len(self.section_list):
                res+=self.section_break(self.section_list[i+1]); self.sect_i=i+1
        return res
    def grid_line_spacing(self,p,style):
        """Exact spacing for a Word lines-only grid without an explicit w:line.

        Word snaps such a line to the next whole grid cell. docxlike's live
        font metrics can disagree with that grid, so write the cell count as
        an exact line spacing and disable the grid snap for this paragraph.
        """
        if not self.section_list: return None
        sect_i=getattr(self,'sect_i',0)
        sect=self.section_list[sect_i] if sect_i<len(self.section_list) else self.section_list[0]
        g=sect.find(q('docGrid'))
        if g is None or g.get(q('type')) not in ('lines','default'): return None
        pitch=whole(g.get(q('linePitch')) or 0)/20
        if pitch<=0: return None
        spacing=p.find(f'{q("pPr")}/{q("spacing")}')
        if spacing is not None and spacing.get(q('line')) is not None: return None
        snap=p.find(f'{q("pPr")}/{q("snapToGrid")}')
        if snap is not None:
            if not on(snap): return None
        else:
            sid=style or self.default_par_style
            while sid:
                st=self.styles_by_id.get(sid)
                if st is None: break
                se=st.find(f'{q("pPr")}/{q("snapToGrid")}')
                if se is not None:
                    if not on(se): return None
                    break
                sid=val(st.find(q('basedOn')))
        sizes=[]
        for sz in p.findall(f'.//{q("r")}/{q("rPr")}/{q("sz")}'):
            sizes.append(whole(val(sz))/2)
        mark=p.find(f'{q("pPr")}/{q("rPr")}/{q("sz")}')
        if mark is not None: sizes.append(whole(val(mark))/2)
        sid=style or self.default_par_style
        while sid and not sizes:
            st=self.styles_by_id.get(sid)
            if st is None: break
            se=st.find(f'{q("rPr")}/{q("sz")}')
            if se is not None:
                sizes.append(whole(val(se))/2); break
            sid=val(st.find(q('basedOn')))
        if not sizes: sizes.append(self.normal_size())
        cells=max(1,math.ceil(max(sizes)*1.3/pitch-1e-9))
        return cells*pitch

    def paragraph1(self,p,story='body'):
        self.par_num=None; self.story=story
        par,other,style=self.ppr(p.find(q('pPr')))
        # a header paragraph without pStyle is Normal in Word; docxlike would use Header there
        if story=='headfoot' and not style: style=self.default_par_style
        if story=='body':
            grid_spacing=self.grid_line_spacing(p,style)
            if grid_spacing is not None:
                par=[x for x in par if not x.startswith('snap-to-grid-when-document-grid-is-defined=')]
                par.append(f'spacing={{line-spacing=exactly,at={grid_spacing:g}bp}}')
                par.append('snap-to-grid-when-document-grid-is-defined=false')
        if self.par_num:
            nid,lvl=self.par_num
            if nid in (None,'0'): other.append('numbering=none')
            elif self.style_lists.get(style)!=(nid,lvl):
                self.used_nums.add(nid)
                other.append('multilevel-list={'+(f'list-library={self.list_name(nid)},' if self.style_lists.get(style,(None,))[0]!=nid else '')+f'change-list-level=level-{lvl+1}'+'}')
        self.display_math=False
        content=self.joined+self.runs(p); self.joined=''
        # nothing after a page break: the paragraph mark takes no line on the new page
        for pb in (self.PAGE_BREAK.strip(),self.PAGE_BREAK.replace(r'\newline ',r'\break ').strip()):
            if content.rstrip().endswith(pb):
                content=content.rstrip()[:-len(pb)]+r'\vadjust{\penalty-10000}'
        # all text hidden: Word sizes the line by the paragraph mark, as for an empty paragraph
        rs=p.findall(f'.//{q("r")}')
        if rs and all(on(r.find(f'{q("rPr")}/{q("vanish")}')) for r in rs if r.find(q('t')) is not None) and any(r.find(q('t')) is not None for r in rs):
            content=''; self.rep.add('paragraph with only hidden text (written empty)')
        self.last_content=content
        # a hidden paragraph mark joins this paragraph to the next one
        mark_e=p.find(f'{q("pPr")}/{q("rPr")}/{q("vanish")}')
        if mark_e is not None and on(mark_e) and story=='body':
            self.joined=content; return None
        opts=[]
        if self.display_math: par=[x for x in par if not x.startswith('alignment=')]+['alignment=centered']
        if style: opts.append(f'style={self.name_of(style)}')
        if par:
            author_par=self.author_paragraph(par)
            opts.append('paragraph={'+','.join(author_par)+'}')
        opts+=other
        mark,_=self.rpr(p.find(f'{q("pPr")}/{q("rPr")}'),base_font_flags=self.paragraph_font_flags)
        spacing_e=p.find(f'{q("pPr")}/{q("spacing")}')
        raw_spacing=(spacing_e is not None and (
            any(whole(spacing_e.get(q(key)) or 0)<0 for key in ('before','after','beforeLines','afterLines'))
            or (spacing_e.get(q('line')) is not None and whole(spacing_e.get(q('line')))<=0)))
        if raw_spacing:
            self.rep.add('paragraph spacing outside supported dialog values (programming route)')
        raw_bottom=any('text-alignment=bottom' in key for key in par)
        if raw_bottom:
            self.rep.add('paragraph Bottom text alignment (baseline approximation; programming route)')
        raw_mark=not content.strip() and self.font_requires_backend(mark)
        if raw_mark:self.rep.add('paragraph-mark font outside supported author controls (programming route)')
        if raw_spacing or raw_bottom or raw_mark or any(key.startswith('tabs=') and 'leader=middle-dot' in key for key in other):
            # Preserve raw OOXML values without inventing a supported author control.
            backend_opts=([f'style={self.name_of(style)}'] if style else [])
            if par: backend_opts.append('paragraph={'+','.join(par)+'}')
            backend_opts+=other
            if not content.strip() and mark: backend_opts.append('font={'+','.join(mark)+'}')
            return ParagraphTeX(r'\csname docxlike_par:nn\endcsname{'+','.join(backend_opts)+'}{'+content+'}')
        if not content.strip() and mark: opts.extend(self.font_options(mark))
        opts=self.paragraph_options(opts)
        paragraph_keys=[key for key in opts if key.startswith('paragraph=')]
        assert len(paragraph_keys)<=1,paragraph_keys
        opts=[key for key in opts if not key.startswith('paragraph=')]
        opts.insert(0,paragraph_keys[0] if paragraph_keys else 'paragraph={}')
        return ParagraphTeX(r'\docxformat['+','.join(opts)+']{'+content+'}')
    def table_style(self,tbl):
        sid=val(tbl.find(f'{q("tblPr")}/{q("tblStyle")}'))
        by_id={x.get(q('styleId')):x for x in (self.styles.findall(q('style')) if self.styles is not None else [])}
        chain=[]
        while sid in by_id and len(chain)<20:
            chain.append(by_id[sid]); sid=val(by_id[sid].find(q('basedOn')))
        if not chain:
            chain=[x for x in by_id.values() if x.get(q('type'))=='table' and x.get(q('default')) in ('1','true')]
        return chain
    def table_prop(self,tbl,chain,path):
        e=tbl.find(f'{q("tblPr")}/{path}')
        for s in chain:
            if e is not None: break
            e=s.find(f'{q("tblPr")}/{path}')
        return e
    def table(self,tbl,breakable=False):
        chain=self.table_style(tbl)
        self.uses_tables=True
        for s in chain:
            if s.find(q('tblStylePr')) is not None: self.rep.add('table style conditional formatting')
            if s.find(q('pPr')) is not None or s.find(q('rPr')) is not None: self.rep.add('table style paragraph/run formatting')
        grid=[whole(g.get(q('w')) or 0) for g in tbl.findall(f'{q("tblGrid")}/{q("gridCol")}')]
        mar=self.table_prop(tbl,chain,q('tblCellMar'))
        def margin(mar,side,alt,default):
            m=mar.find(q(side)) if mar is not None else None
            if m is None and mar is not None: m=mar.find(q(alt))
            return whole(m.get(q('w'))) if m is not None and m.get(q('type')) in (None,'dxa') else default
        left,right=margin(mar,'left','start',108),margin(mar,'right','end',108)
        top,bottom=margin(mar,'top','top',0),margin(mar,'bottom','bottom',0)
        bd=self.table_prop(tbl,chain,q('tblBorders'))
        def border_of(parent,side):
            e=parent.find(q(side)) if parent is not None else None
            if e is None and side in ('left','right') and parent is not None: e=parent.find(q({'left':'start','right':'end'}[side]))
            if e is None: return None
            v=val(e)
            if v in ('nil','none'): return ('none',0)
            if v not in ('single','double'): self.rep.add(f'table border style {v} (drawn single)'); v='single'
            if e.get(q('color')) not in (None,'auto','000000'): self.rep.add('table border colour')
            return (v,whole(e.get(q('sz')) or 4))
        tb={side:(border_of(bd,side) or ('none',0)) for side in ('top','left','bottom','right','insideH','insideV')}
        borders={side:tb[side][0]!='none' for side in tb}
        widths={w for v,w in tb.values() if v!='none'}
        rows=tbl.findall(q('tr'))
        # cells by grid column; a vMerge continuation keeps its place but has no content
        layout=[]
        for tr in rows:
            col=0; cells=[]
            trpr=tr.find(q('trPr'))
            before=trpr.find(q('gridBefore')) if trpr is not None else None
            if before is not None: col+=whole(val(before)); self.rep.add('table row gridBefore')
            for tc in tr.findall(q('tc')):
                pr=tc.find(q('tcPr'))
                span=whole(val(pr.find(q('gridSpan')),default='1')) if pr is not None else 1
                vm=pr.find(q('vMerge')) if pr is not None else None
                vmerge=None if vm is None else (val(vm) or 'continue')
                va=val(pr.find(q('vAlign'))) if pr is not None else None
                if pr is not None:
                    for x in ('textDirection','noWrap','tcFitText','hMerge'):
                        if pr.find(q(x)) is not None: self.rep.add(f'table cell {x}')
                cm=pr.find(q('tcMar')) if pr is not None else None
                mg=(margin(cm,'left','start',left),margin(cm,'right','end',right),margin(cm,'top','top',top),margin(cm,'bottom','bottom',bottom))
                cb=pr.find(q('tcBorders')) if pr is not None else None
                own_b={side:border_of(cb,side) for side in ('top','left','bottom','right')} if cb is not None else {}
                shd=pr.find(q('shd')) if pr is not None else None
                fill=shd.get(q('fill')) if shd is not None and shd.get(q('fill')) not in (None,'auto') else None
                if shd is not None and val(shd) not in (None,'clear','nil'): self.rep.add('table cell shading pattern (fill kept)')
                cells.append(dict(tc=tc,col=col,span=span,vmerge=vmerge,valign=va,mar=mg,own=cm is not None or any(own_b.get(x) for x in ('left','right')),
                                  ob=own_b,fill=fill)); col+=span
            for x in tr.findall(q('sdt')): self.rep.add('table row sdt')
            layout.append(cells)
        heights=[]; header=[]
        for tr in rows:
            trpr=tr.find(q('trPr'))
            h=trpr.find(q('trHeight')) if trpr is not None else None
            if h is not None and h.get(q('hRule'))!='auto':
                if h.get(q('hRule'))=='exact': self.rep.add('table row exact height (taken as at least)')
                heights.append(whole(val(h) or 0))
            else: heights.append(0)
            # a row never breaks inside (cantSplit holds); header rows repeat on each page in a longtable
            hdr=trpr.find(q('tblHeader')) if trpr is not None else None
            header.append(hdr is not None and bool(on(hdr)))
            if hdr is not None and not breakable: self.rep.add('table row tblHeader (table in a cell or header: not repeated)')
        # cell margins are written per column with @{}: tcMar can differ from cell to cell
        def width(c): return sum(grid[c['col']:c['col']+c['span']])-c['mar'][0]-c['mar'][1]
        def vrule(b): return {'none':'','single':'|','double':'||'}[b[0]] if b else ''
        # one margin for every cell: \tabcolsep; margins of their own: explicit @{} on each column
        explicit=left!=right or any(c['mar'][:2]!=(left,right) for row in layout for c in row)
        def column(col,span,l,r,w,t='p',ob=None):
            ob=ob or {}
            lr=vrule(ob['left']) if ob.get('left') else (vrule(tb['left']) if col==0 else '')
            rr=vrule(ob['right']) if ob.get('right') else vrule(tb['right'] if col+span>=len(grid) else tb['insideV'])
            if not explicit: return f'{lr}{t}{{{bp(max(w,0))}}}{rr}'
            return f'{lr}@{{\\hspace*{{{bp(l)}}}}}{t}{{{bp(max(w,0))}}}@{{\\hspace*{{{bp(r)}}}}}{rr}'
        def colspec(c,prev_multi=False):
            t={'center':'m','bottom':'b'}.get(c['valign'],'p')
            spec=column(c['col'],c['span'],c['mar'][0],c['mar'][1],width(c),t,c['ob'])
            if c['col']==0 or not explicit: return spec
            # array gives the material between two columns to the left one: a later \multicolumn
            # starts at its p, and a different left margin of its own goes inside the cell
            spec='@{}'+spec[spec.index(t+'{'):]
            # after a plain cell the left margin is already there; after a \multicolumn it is not
            if prev_multi: spec=f'@{{\\hspace*{{{bp(c["mar"][0])}}}}}'+spec[3:]
            elif c['mar'][0]!=left:
                spec=f'@{{\\hspace*{{{bp(c["mar"][0]-left)}}}}}'+spec[3:].replace(f'{t}{{{bp(max(width(c),0))}}}',f'{t}{{{bp(max(width(c)-(c["mar"][0]-left),0))}}}',1)
            if c['ob'].get('left'): self.rep.add('table cell left border on a later column (not drawn)')
            return spec
        spec=''.join(column(i,1,left,right,g-left-right) for i,g in enumerate(grid))
        # rows a vMerge restart covers
        down={}
        for r,cells in enumerate(layout):
            for c in cells:
                if c['vmerge']=='restart':
                    n=1
                    while r+n<len(layout) and any(x['col']==c['col'] and x['vmerge']=='continue' for x in layout[r+n]): n+=1
                    down[(r,c['col'])]=n
        def edge(r):
            # the border between row r-1 and row r: per column the cells' own borders, else the table's
            above=layout[r-1] if r>0 else []; below=layout[r] if r<len(layout) else []
            default=tb['top'] if r==0 else tb['bottom'] if r==len(layout) else tb['insideH']
            cols={}
            for c in above:
                if c['ob'].get('bottom'):
                    for k in range(c['col'],c['col']+c['span']): cols[k]=c['ob']['bottom']
            for c in below:
                b=c['ob'].get('top')
                if c['vmerge']=='continue': b=('none',0)
                for k in range(c['col'],c['col']+c['span']):
                    if b is not None: cols[k]=b if b[0]!='none' or k not in cols else cols[k]
                    elif k not in cols: cols[k]=default
            for k in range(len(grid)): cols.setdefault(k,default)
            kinds={cols[k] for k in range(len(grid))}
            # in a longtable a page can break only where there is a break point: one after each rule
            brk='\\penalty0' if breakable else ''
            if kinds=={('none',0)} or not grid: return f' \\noalign{{{brk}}}' if brk and 0<r<len(layout) else ''
            if len(kinds)==1:
                v,w=kinds.pop(); h=f'{w/8:g}bp'
                if v=='double': return f' \\noalign{{\\hrule height{h}\\vskip{h}\\hrule height{h}{brk}}}'
                return f' \\noalign{{\\hrule height{h}{brk}}}'
            ranges=[]
            for k in range(len(grid)):
                if cols[k][0]=='none': continue
                if ranges and ranges[-1][1]==k: ranges[-1][1]=k+1
                else: ranges.append([k+1,k+1])
            if len({w for v,w in cols.values() if v!='none'})>1 or any(v=='double' for v,w in cols.values()):
                self.rep.add('table partial border of mixed width or style (drawn single)')
            return ''.join(f' \\cline{{{a}-{b}}}' for a,b in ranges)+(f' \\noalign{{{brk}}}' if brk else '')
        body=[]
        for r,cells in enumerate(layout):
            parts=[]; prev_multi=False
            for c in cells:
                if c['vmerge']=='continue': inner=''
                else:
                    pars=[]
                    for x in c['tc']:
                        n=x.tag.replace(W,'')
                        if n=='p': pars+=self.paragraph(x,story='cell')
                        elif n=='tbl': pars.append(self.table(x))
                        elif n=='sdt':
                            sc=x.find(q('sdtContent'))
                            for y in (sc.findall(q('p')) if sc is not None else []): pars+=self.paragraph(y,story='cell')
                        elif n!='tcPr': self.rep.add(f'table cell/{n}')
                    inner='\n'.join(pars)
                    # top and bottom cell margins as empty boxes above and below the paragraphs
                    if c['mar'][2]: inner=f'\\vbox to{bp(c["mar"][2])}{{}}\\nointerlineskip\n'+inner
                    if c['mar'][3]: inner+=f'\n\\nointerlineskip\\vbox to{bp(c["mar"][3])}{{}}'
                    if down.get((r,c['col']),1)>1: inner=f'\\multirow[t]{{{down[(r,c["col"])]}}}{{*}}{{\\parbox[t]{{{bp(max(width(c),0))}}}{{{inner}}}}}'; self.uses_multirow=True
                if c['fill']: inner=f'\\cellcolor[HTML]{{{c["fill"]}}}'+inner; self.uses_colortbl=True
                if c['span']>1 or c['valign'] in ('center','bottom') or c['own']:
                    inner=f'\\multicolumn{{{c["span"]}}}{{{colspec(c,prev_multi)}}}{{{inner}}}'
                    prev_multi=True
                else: prev_multi=False
                parts.append(inner)
            line=(f'\\docxrow{{specify-height={bp(heights[r])}}}\n' if heights[r] else '')+' &\n'.join(parts)+' \\\\'
            if r+1<len(layout): line+=edge(r+1)
            body.append(line)
        jc=val(self.table_prop(tbl,chain,q('jc')))
        ind=self.table_prop(tbl,chain,q('tblInd'))
        indent=whole(ind.get(q('w')) or 0) if ind is not None and ind.get(q('type')) in (None,'dxa') else 0
        if tbl.find(f'{q("tblPr")}/{q("tblpPr")}') is not None: self.rep.add('floating table (placed inline)')
        rule=f'\\setlength\\arrayrulewidth{{{max(widths)/8:g}bp}}' if widths else ''
        setup=[] if explicit else [f'\\setlength\\tabcolsep{{{bp(left)}}}']
        env='longtable' if breakable else 'tabular'
        nh=0
        while nh<len(header) and header[nh]: nh+=1
        if breakable and 0<nh<len(body): body[nh-1]+='\n\\endhead'
        tab=('\\begin{'+env+'}{'+spec+'}\n'+edge(0).strip()+'\n'+'\n'.join(body)+edge(len(layout))+'\n\\end{'+env+'}')
        # Word 2003-2010 layout moves the table out by the first and last cell margins so the text lines
        # up with the body; 2013 puts the text at the indent plus max(margin + border/2, border)
        first=layout[0][0]['mar'][0] if layout and layout[0] else left
        last=layout[0][-1]['mar'][1] if layout and layout[0] else right
        lb=(layout[0][0]['ob'].get('left') if layout and layout[0] else None) or tb['left']
        bw=(lb[1]*(3 if lb[0]=='double' else 1))*2.5 if lb[0]!='none' else 0  # eighths of a point to twips
        if self.compat<15: shift_l,shift_r=indent-first,-last
        else: shift_l,shift_r=indent+max(bw/2,bw-first),bw/2
        if breakable:
            # a body table breaks between rows across pages: longtable, placed with \LTleft and \LTright
            self.uses_longtable=True
            lt={'center':(r'\fill',r'\fill'),'right':(r'\fill',bp(shift_r)),'end':(r'\fill',bp(shift_r))}.get(jc,(bp(shift_l),r'\fill'))
            box=(f'\\setlength\\LTleft{{{lt[0]}}}\\setlength\\LTright{{{lt[1]}}}'
                 '\\setlength\\LTpre{0pt}\\setlength\\LTpost{0pt}'+tab)
        elif jc=='center': box='\\hbox to\\linewidth{\\hfil'+tab+'\\hfil}'
        elif jc in ('right','end'): box='\\hbox to\\linewidth{\\hfil'+tab+f'\\hspace*{{{bp(shift_r)}}}'+'}'
        else: box='\\hbox{'+f'\\hspace*{{{bp(shift_l)}}}'+tab+'}'
        # Every cell holds formatted paragraphs with Word line boxes, so no additional row strut is needed.
        setup.insert(0,'\\renewcommand\\arraystretch{0}')
        return '\\par\\nointerlineskip\n{'+rule+''.join(setup)+box+'}\\nointerlineskip'
    def group_border(self,out,i_prev,prev,cur):
        # paragraphs with the same borders form one box in Word: the inner bottom/top pair becomes the
        # between border, with the space of the bottom border above it
        bdr=cur.find(f'{q("pPr")}/{q("pBdr")}')
        border_key='borders={' if 'borders={' in out[i_prev] else 'border={'
        head,sep,tail=out[i_prev].partition(border_key)
        tail=re.sub(r',?bottom=\{[^{}]*\}','',tail,count=1)
        out[i_prev]=ParagraphTeX((head+sep+tail).replace(border_key+',',border_key).replace('[,','[').replace(',]',']').replace('[]',''))
        i=len(out)-1
        while i>i_prev and not isinstance(out[i],ParagraphTeX): i-=1
        if i<=i_prev: return
        between=bdr.find(q('between'))
        bottom=bdr.find(q('bottom'))
        new=self.border_side(between,whole(bottom.get(q('space')) or 0) if bottom is not None else 0) if between is not None else None
        out[i]=ParagraphTeX(re.sub(r'top=\{[^{}]*\}',('top='+new) if new else '',out[i],count=1).replace('borders={,','borders={').replace(',}','}'))
    def frame_keys(self,f):
        k=[]
        k.append('text-wrapping='+('none' if f.get(q('wrap')) in ('notBeside','none','topAndBottom') else 'around'))
        size=[]
        if f.get(q('w')): size.append(f'width={bp(f.get(q("w")))}')
        if f.get(q('h')):
            size.append(f'height={bp(f.get(q("h")))}')
            if f.get(q('hRule'))=='exact': self.rep.add('frame exact height (taken as at least)')
        if size: k.append('size={'+','.join(size)+'}')
        # text wraps a frame on both sides in Word 2013 layout, on the larger side before it
        k.append('wrap-text='+('both-sides' if self.compat>=15 else 'largest'))
        hrel={'margin':'margin','page':'page','text':'column'}.get(f.get(q('hAnchor'),'text'),'column')
        xa=f.get(q('xAlign'))
        xpos=xa if xa in ('left','center','right') else bp(f.get(q('x'))) if f.get(q('x')) else 'left'
        if xa and xa not in ('left','center','right'): self.rep.add(f'frame xAlign={xa} (left used)')
        k.append(f'horizontal={{position={xpos},relative-to={hrel}}}')
        vrel={'margin':'margin','page':'page','text':'paragraph'}.get(f.get(q('vAnchor'),'text'),'paragraph')
        if vrel!='paragraph' and k[0]=='text-wrapping=none':
            # docxlike places a frame without wrapping only relative to its paragraph
            self.rep.add(f'frame without wrapping positioned relative to the {vrel} (placed at its paragraph)'); vrel='paragraph'
            y=0
        else: y=f.get(q('y')) or 0
        if f.get(q('yAlign')): self.rep.add(f'frame yAlign={f.get(q("yAlign"))} (offset 0 used)')
        k.append(f'vertical={{position={bp(y)},relative-to={vrel}}}')
        hs,vs=bp(f.get(q('hSpace')) or 0),bp(f.get(q('vSpace')) or 0)
        k.append(f'distance-from-text={{left={hs},right={hs},top={vs},bottom={vs}}}')
        if f.get(q('dropCap')) not in (None,'none'): self.rep.add('drop cap (set as a frame)')
        return k
    def frame(self,group):
        # paragraphs with the same w:framePr share one frame in Word
        first=group[0]
        par,other,style=self.ppr(first.find(q('pPr')))
        par=[x for x in par if not x.startswith('pagination')]
        keys=self.frame_keys(first.find(f'{q("pPr")}/{q("framePr")}'))
        if style: keys.insert(0,f'style={self.name_of(style)}')
        fmt=(['paragraph={'+','.join(par)+'}'] if par else [])+[o for o in other if not o.startswith(('numbering','multilevel'))]
        if fmt: keys.insert(1 if style else 0,'format={'+','.join(fmt)+'}')
        content='\\break '.join(self.paragraph_runs(x) for x in group)
        return r'\csname docxlike_frame:nn\endcsname{'+','.join(keys)+'}{'+content+'}'
    def body(self):
        out=[]; prev=None; i_prev=None
        children=list(self.doc.find(q('body')))
        skip=set()
        for idx,e in enumerate(children):
            if idx in skip: continue
            n=e.tag.replace(W,'')
            fp=e.find(f'{q("pPr")}/{q("framePr")}') if n=='p' else None
            if fp is not None:
                sig=ET.tostring(fp); group=[e]; j=idx+1
                while j<len(children) and children[j].tag==q('p'):
                    f2=children[j].find(f'{q("pPr")}/{q("framePr")}')
                    if f2 is None or ET.tostring(f2)!=sig: break
                    group.append(children[j]); skip.add(j); j+=1
                out.append(self.frame(group)); prev=None; i_prev=None
                continue
            if n=='p':
                b=e.find(f'{q("pPr")}/{q("pBdr")}')
                sig=ET.tostring(b) if b is not None else None
                start=len(out)
                out.extend(self.paragraph(e))
                if sig and prev is not None and sig==prev[0] and i_prev is not None: self.group_border(out,i_prev,prev[1],e)
                prev=(sig,e) if sig else None
                i_prev=next((k for k in range(start,len(out)) if isinstance(out[k],ParagraphTeX)),None) if sig else None
                continue
            elif n=='tbl':
                # longtable works only in one column; a table in a multi-column section stays in one piece
                sect=self.section_list[getattr(self,'sect_i',0)] if self.section_list else None
                cols=sect.find(q('cols')) if sect is not None else None
                out.append(self.table(e,breakable=cols is None or whole(cols.get(q('num')) or 1)<=1))
            elif n=='sdt':
                c=e.find(q('sdtContent'))
                if c is not None:
                    for p in c.findall(q('p')): out.extend(self.paragraph(p))
                    self.rep.add('block sdt (content kept, control dropped)')
            elif n=='sectPr': pass
            else: self.rep.add(f'body/{n}')
        return out

    def font_preamble(self,normal):
        # Normal's Latin and Asian fonts become the main fonts; each name is registered once
        lines=[]; n=0; nlat=nasi=None
        rpr=normal.find(q('rPr')) if normal is not None else None
        dd=self.styles.find(f'{q("docDefaults")}/{q("rPrDefault")}/{q("rPr")}') if self.styles is not None else None
        for src in (rpr,dd):
            if src is not None and src.find(q('rFonts')) is not None:
                lat,asi=self.fonts(src.find(q('rFonts'))); nlat=nlat or lat; nasi=nasi or asi
        used=set(self.fonts_used)|({(nlat,False)} if nlat else set())|({(nasi,True)} if nasi else set())
        register={}
        def opts(m):
            # A system-font entry keeps the Word family name and omits Path, so
            # fontspec resolves the installed font instead of a bundled file.
            # Word prints quotes and hyphens as typed; fontspec's TeX ligatures
            # would curl ' and " and join --.
            parts=[]
            if m.get('path'): parts.append(f'Path={{{m["path"]}}}')
            if 'index' in m: parts.append(f'FontIndex={m["index"]}')
            parts += [f'{k}={{{m[f]}}}' for f,k in (('bold','BoldFont'),('italic','ItalicFont'),('bolditalic','BoldItalicFont')) if f in m]
            parts += ['Kerning=Off','Ligatures=TeXOff']
            return '['+','.join(parts)+']'
        for name,asian in sorted(used,key=lambda t:(t[1],t[0])):
            m=self.font_map.get(name)
            if not m and (self.font_map.get('*') or {}).get('system'):
                m={'system':True,'asian':asian}
            if not m: continue
            if asian and not m.get('asian'):
                # a Latin font named for East Asian text has no CJK glyphs; Windows Word falls back to SimSun
                fallback=self.font_map.get('SimSun')
                if not fallback: continue
                self.rep.add(f'East Asian font {name} has no CJK glyphs (SimSun used)'); m=fallback
            spec=m.get('file') or name
            if not asian:
                if name==nlat: lines.append(r'\setmainfont{'+spec+'}'+opts(m)); register[name]=r'\rmfamily'
                else:
                    n+=1; cs=f'\\DocxLatin{chr(64+n)}'; lines.append(r'\newfontfamily'+cs+'{'+spec+'}'+opts(m)); register[name]=cs
            else:
                if name==nasi:
                    lines.append(r'\setmainjfont{'+spec+'}'+opts(m)); register.setdefault(name,r'\mcfamily')
                elif name not in register:
                    n+=1; cs=f'\\DocxAsian{chr(64+n)}'; lines.append(r'\newjfontfamily'+cs+'{'+spec+'}'+opts(m)); register[name]=cs
        for name,cs in register.items():
            lines.append(r'\ExplSyntaxOn\docxlike_font_gset:nn{'+name.replace(' ','~')+'}{'+cs+r'}\ExplSyntaxOff')
        return lines
    def convert(self):
        normal=None
        for s in (self.styles.findall(q('style')) if self.styles is not None else []):
            if s.get(q('type'))=='paragraph' and s.get(q('default')) in ('1','true'): normal=s
        if normal is None and self.styles is not None:
            # a styles part that marks no default: Word still uses the style called Normal
            normal=next((s for s in self.styles.findall(q('style')) if s.get(q('styleId'))=='Normal'),None)
        self.section_list=self.sections()
        setup=self.settings_keys()+self.page_keys(self.normal_size())
        style_keys=self.style_block()
        body=self.body()
        headfoot=self.headers_footers()
        numdefs=self.numbering_defs()
        note_keys=self.note_keys()
        fonts=self.font_preamble(normal)
        head=[r'\documentclass{article}',r'\usepackage[preset=none]{docxlike}']
        if getattr(self,'uses_links',False): head.append(r'\usepackage[hidelinks]{hyperref}')
        if getattr(self,'uses_tables',False): head.append(r'\usepackage{array}')
        if getattr(self,'uses_longtable',False): head.append(r'\usepackage{longtable}')
        if getattr(self,'uses_graphics',False): head.append(r'\usepackage{graphicx}')
        if getattr(self,'uses_math',False):
            # Word sets equations in Cambria Math
            m=self.font_map.get('Cambria Math')
            head.append(r'\usepackage{amsmath,unicode-math}')
            head.append(r'\setmathfont{'+m['file']+'}[Path={'+m['path']+'}'+(f',FontIndex={m["index"]}' if 'index' in m else '')+']' if m else r'\setmathfont{Cambria Math}')
        if getattr(self,'uses_multirow',False): head.append(r'\usepackage{multirow}')
        if getattr(self,'uses_colortbl',False): head.append(r'\usepackage[table]{xcolor}')
        head+=[r'\ExplSyntaxOn\docxlike_body_setup:n{}\ExplSyntaxOff']
        if self.languages:
            head.append(r'\csname docxlike_languages_load:n\endcsname{'+','.join(self.languages[k] for k in sorted(self.languages))+'}')
        head+=fonts
        head.append(r'\csname docxlike_setup:n\endcsname{'+','.join(setup+style_keys+note_keys)+'}')
        head+=numdefs+headfoot
        # STYLEREF reads marks of the styles it names, which must be declared in the preamble
        refs=set()
        for m in re.finditer(r'\\docxinsert\[field\]\{\s*STYLEREF\s+(?:"([^"]+)"|([^\\}"]+))','\n'.join(body+headfoot)):
            refs.add((m.group(1) or m.group(2)).strip())
        head+=[r'\csname docxlike_mark_new_class:n\endcsname{'+name+'}' for name in sorted(refs) if name]
        rep=['% Converted by tools/docx2docxlike.py. Not converted:']+[f'%   {k} ({v}x)' for k,v in sorted(self.rep.items.items())]
        # preset=none leaves the page style alone; the package style prints registered header/footer stories.
        start=r'\begin{document}\pagestyle{docxlike}' if getattr(self,'any_headfoot',False) else r'\begin{document}\pagestyle{empty}'
        return '\n'.join(rep+head+[start]+body+[r'\end{document}'])+'\n'

def main():
    ap=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('docx',type=Path); ap.add_argument('tex',type=Path)
    ap.add_argument('--font-map',type=Path); ap.add_argument('--report',type=Path)
    ap.add_argument('--paragraph-defaults',type=Path,help='Target-application paragraph spacing JSON, used only when pPrDefault is omitted')
    a=ap.parse_args()
    fm=json.loads(a.font_map.read_text()) if a.font_map else None
    # images go to <tex name>-media/ next to the .tex
    media=a.tex.parent/(a.tex.stem+'-media')
    defaults=json.loads(a.paragraph_defaults.read_text()) if a.paragraph_defaults else None
    try:
        c=Converter(a.docx,fm,media_dir=media,media_prefix=media.name+'/',paragraph_defaults=defaults)
    except ValueError as error:
        ap.error(str(error))
    a.tex.write_text(c.convert())
    if a.report: a.report.write_text(json.dumps(dict(c.rep.items),ensure_ascii=False,indent=1)+'\n')
    print(f'{a.docx.name}: {sum(c.rep.items.values())} items not converted ({len(c.rep.items)} kinds)')

if __name__=='__main__': main()
