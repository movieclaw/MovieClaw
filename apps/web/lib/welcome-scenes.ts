/**
 * 欢迎页（登录 / 初始化）轮播的影史经典台词，与原生 App 同一份
 * （apps/apple/Shared/Welcome/WelcomeScenes.swift，由脚本转出，改动两边同步）。
 *
 * 选句口径：美国电影学会「百年百大电影台词」里最广为人知的那些，加上华语与世界影史的名句；
 * 只收能确认原话的句子，基调偏温暖与诗意。外语片附中文字幕，注明片名与年份。
 * 不用真实海报 / 剧照：登录前拿不到用户自己的片库，把别人的海报放进开源项目也有版权问题。
 * 台词用思源宋体子集显示（app/fonts/WelcomeSerif.otf，与 App 同一份，子集外的字回落系统衬线体）。
 */
export interface WelcomeScene {
  /** 中文（华语片为原句，外语片为字幕）；\n 断在语气停顿处 */
  line: string;
  /** 外语原句（华语片为 null） */
  original: string | null;
  film: string;
  year: number;
}

const QUOTES: Array<[string, string | null, string, number]> = [
  // 美国电影学会百大台词
  ["毕竟，明天又是新的一天。", "After all, tomorrow is another day.", "乱世佳人", 1939],
  ["我会给他一个无法拒绝的条件。", "I'm gonna make him an offer he can't refuse.", "教父", 1972],
  ["我本来可以出人头地的。", "I coulda been a contender.", "码头风云", 1954],
  ["没有什么地方比得上家。", "There's no place like home.", "绿野仙踪", 1939],
  ["我们永远拥有巴黎。", "We'll always have Paris.", "卡萨布兰卡", 1942],
  ["好了，德米尔先生，\n我准备好拍特写了。", "All right, Mr. DeMille,\nI'm ready for my close-up.", "日落大道", 1950],
  ["愿原力与你同在。", "May the Force be with you.", "星球大战", 1977],
  ["系好安全带，\n今晚会是个颠簸的夜晚。", "Fasten your seatbelts.\nIt's going to be a bumpy night.", "彗星美人", 1950],
  ["你在跟我说话吗？", "You talkin' to me?", "出租车司机", 1976],
  ["爱就是永远不必说抱歉。", "Love means never having to say you're sorry.", "爱情故事", 1970],
  ["那是构成梦的材料。", "The stuff that dreams are made of.", "马耳他之鹰", 1941],
  ["E.T. 打电话回家。", "E.T. phone home.", "E.T. 外星人", 1982],
  ["是美女杀死了野兽。", "It was Beauty killed the Beast.", "金刚", 1933],
  ["我是邦德，詹姆斯·邦德。", "Bond. James Bond.", "诺博士", 1962],
  ["你需要一条更大的船。", "You're gonna need a bigger boat.", "大白鲨", 1975],
  ["我会回来的。", "I'll be back.", "终结者", 1984],
  ["妈妈说，人生就像一盒巧克力，\n你永远不知道下一块是什么味道。", "My mama always said life was like a box of chocolates.\nYou never know what you're gonna get.", "阿甘正传", 1994],
  ["你一开口，我就被你打动了。", "You had me at hello.", "甜心先生", 1996],
  ["你把它建起来，他就会来。", "If you build it, he will come.", "梦幻之地", 1989],
  ["嗯，人无完人。", "Well, nobody's perfect.", "热情如火", 1959],
  ["玫瑰花蕾。", "Rosebud.", "公民凯恩", 1941],
  ["我们有时都会有点疯狂。", "We all go a little mad sometimes.", "惊魂记", 1960],
  ["亲近你的朋友，\n更要亲近你的敌人。", "Keep your friends close,\nbut your enemies closer.", "教父 2", 1974],
  ["休斯顿，我们遇到麻烦了。", "Houston, we have a problem.", "阿波罗 13 号", 1995],
  ["你跳，我也跳。", "You jump, I jump.", "泰坦尼克号", 1997],
  // 世界影史
  ["希望是美好的，也许是人间至善，\n而美好的事物永不消逝。", "Hope is a good thing, maybe the best of things,\nand no good thing ever dies.", "肖申克的救赎", 1994],
  ["抓住今天，孩子们，\n让你们的生命超凡脱俗。", "Carpe diem. Seize the day, boys.\nMake your lives extraordinary.", "死亡诗社", 1989],
  ["不管你将来做什么，都要爱它，\n就像你小时候爱放映室那样。", "Whatever you end up doing, love it.", "天堂电影院", 1988],
  ["陆地？对我来说，\n陆地是一艘太大的船。", "Land? Land is a ship too big for me.", "海上钢琴师", 1998],
  ["人生总是这么痛苦吗？\n还是只有小时候是这样？\n——总是如此。", "Is life always this hard,\nor is it just when you're a kid?\nAlways like this.", "这个杀手不太冷", 1994],
  ["这不是你的错。", "It's not your fault.", "心灵捕手", 1997],
  ["假如再也见不到你，\n祝你早安、午安、晚安。", "In case I don't see ya,\ngood afternoon, good evening, and good night!", "楚门的世界", 1998],
  ["罗马！无论如何，是罗马。", "Rome! By all means, Rome.", "罗马假日", 1953],
  ["如果你跳错了，缠在一起了，\n那就继续跳下去。", "If you make a mistake, get all tangled up,\njust tango on.", "闻香识女人", 1992],
  ["早安，公主！", "Buongiorno, principessa!", "美丽人生", 1997],
  ["救一人，即救全世界。", "Whoever saves one life saves the world entire.", "辛德勒的名单", 1993],
  ["他们可以夺走我们的生命，\n但永远夺不走我们的自由！", "They may take our lives,\nbut they'll never take our freedom!", "勇敢的心", 1995],
  ["我们生前的所作所为，\n将在永恒中回响。", "What we do in life echoes in eternity.", "角斗士", 2000],
  ["我们唯一能决定的，\n是如何利用被赋予的时间。", "All we have to decide is what to do\nwith the time that is given to us.", "指环王：护戒使者", 2001],
  ["根本没有勺子。", "There is no spoon.", "黑客帝国", 1999],
  ["路？我们要去的地方，不需要路。", "Roads? Where we're going, we don't need roads.", "回到未来", 1985],
  ["如果你有梦想，就要守护它。", "You got a dream, you gotta protect it.", "当幸福来敲门", 2006],
  ["记住你是谁。", "Remember who you are.", "狮子王", 1994],
  ["飞向宇宙，浩瀚无垠！", "To infinity and beyond!", "玩具总动员", 1995],
  ["冒险就在那里！", "Adventure is out there!", "飞屋环游记", 2009],
  ["为什么这么严肃？", "Why so serious?", "蝙蝠侠：黑暗骑士", 2008],
  ["别害怕把梦做得更大一点，亲爱的。", "You mustn't be afraid to dream\na little bigger, darling.", "盗梦空间", 2010],
  ["能力越大，责任越大。", "With great power comes great responsibility.", "蜘蛛侠", 2002],
  ["沉湎于梦想而忘记生活，\n是没有好处的。", "It does not do to dwell on dreams\nand forget to live.", "哈利·波特与魔法石", 2001],
  ["敬那些做梦的人，\n哪怕他们看起来有点傻。", "Here's to the ones who dream,\nfoolish as they may seem.", "爱乐之城", 2016],
  ["曾经发生过的事情不可能忘记，\n只不过是想不起来而已。", null, "千与千寻", 2001],
  // 仰望星空
  ["我们曾经仰望星空，\n思考自己在星辰间的位置。", "We used to look up at the sky and wonder\nat our place in the stars.", "星际穿越", 2014],
  ["不要温和地走进那个良夜。", "Do not go gentle into that good night.", "星际穿越", 2014],
  ["所有这些时刻，终将消逝在时光中，\n一如雨中的泪水。", "All those moments will be lost in time,\nlike tears in rain.", "银翼杀手", 1982],
  ["抱歉，戴夫，恐怕我做不到。", "I'm sorry, Dave. I'm afraid I can't do that.", "2001太空漫游", 1968],
  ["如果宇宙中只有我们，\n那真是太浪费空间了。", "If it's just us,\nit seems like an awful waste of space.", "超时空接触", 1997],
  ["如果你能从头到尾看清自己的一生，\n你会改变什么吗？", "If you could see your whole life from start to finish,\nwould you change things?", "降临", 2016],
  // 华语电影
  ["念念不忘，必有回响。", null, "一代宗师", 2013],
  ["如果记忆也是一个罐头的话，\n我希望这一个罐头不会过期。", null, "重庆森林", 1994],
  ["说的是一辈子！差一年、一个月、\n一天、一个时辰，都不算一辈子！", null, "霸王别姬", 1993],
  ["这世界上有一种鸟是没有脚的，\n它只可以一直飞呀飞，\n飞累了就在风里面睡觉。", null, "阿飞正传", 1990],
  ["那个时代已过去，\n属于那个时代的一切，都不存在了。", null, "花样年华", 2000],
  ["当你不能够再拥有的时候，\n你唯一可以做的，就是令自己不要忘记。", null, "东邪西毒", 1994],
  ["对不起，我是警察。", null, "无间道", 2002],
  ["如果非要在这份爱上加一个期限，\n我希望是……一万年。", null, "大话西游之大圣娶亲", 1995],
  ["让子弹飞一会儿。", null, "让子弹飞", 2010],
  ["把手握紧，里面什么也没有；\n把手松开，你拥有的是一切。", null, "卧虎藏龙", 2000],
  ["不管最终结果将人类历史导向何处，\n我们决定，选择希望。", null, "流浪地球", 2019],
];

export const WELCOME_SCENES: WelcomeScene[] = QUOTES.map(([line, original, film, year]) => ({
  line,
  original,
  film,
  year,
}));

/** 打乱一份台词顺序（每次打开首页、一轮放完时各打乱一次） */
export function shuffledScenes(): WelcomeScene[] {
  const list = [...WELCOME_SCENES];
  for (let i = list.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [list[i], list[j]] = [list[j], list[i]];
  }
  return list;
}
